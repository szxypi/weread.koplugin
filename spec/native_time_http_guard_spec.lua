package.path='./?.lua;'..package.path
local F=require('spec.helpers.thought_edit_fixture')
local Guard=require('spec.koreader.native_time_http_guard')
local Protocol=require('weread.lib.protocol')
local Cookie=require('weread.lib.cookie')
local checks=0
local function expect(value) checks=checks+1;assert(value,'check '..checks) end
local function fixture(options)
    options=options or {};local client=F.codec();client.settings={}
    local grant={vid='900000',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'..string.rep('1',19)}
    local cookies={wr_vid = grant.vid,wr_skey='synthetic-cookie'};local state={calls=0,events={},current=true}
    local reply=client:json_encode({succ=options.response==false and 0 or 1})
    function client:request(request)
        assert(request.redirect==false)
        state.calls=state.calls+1
        if options.throw then error('synthetic transport') end
        if options.oversized then request.sink(string.rep('x',65537));return reply,200,{} end
        request.sink(reply);request.sink(nil)
        return options.mismatch and self:json_encode({succ=1}) or nil,options.code or 200,{}
    end
    local guard=Guard.install(client,{grant=grant,book_id='900001',chapter_uid='11',cookies=cookies,months={1698796800},now=function() return 1700000000 end,
        current=function() return state.current end,selection=function() return {synthetic=true} end,
        record=function() return {phase='claimed',synthetic=true} end,rpc=function(kind,value)
            state.events[#state.events+1]={kind=kind,value=value}
            if kind=='claim' then return not options.deny end
            return value.status==200 and value.response.succ==1
        end})
    local function native(url,method,api,body)
        return {url=url,method=method,body=body,diagnostic_api=api,headers={vid=grant.vid,accessToken=grant.accessToken},
            skip_cookie=true,persist_response_cookies=false,sensitive=true,sink=function() return 1 end}
    end
    local function web(url,method,body,api,account)
        local h={Cookie=Cookie.to_header(cookies),Origin='https://weread.qq.com'}
        if account then h['X-Vid']=grant.vid;h['X-Skey']=cookies.wr_skey end
        return {url=url,method=method,body=body,diagnostic_api=api,headers=h,skip_cookie=true,
            persist_response_cookies=false,sensitive=true,sink=function() return 1 end}
    end
    return client,guard,state,native,web,grant,cookies
end

do
    local client,guard,state,native,web=fixture()
    local reads={
        native('https://i.weread.qq.com/book/info?bookId=900001','GET','native_time_metadata'),
        native('https://i.weread.qq.com/book/getProgress?bookId=900001','GET','native_time_progress'),
        native('https://i.weread.qq.com/shelf/sync','GET','native_shelf'),
        native('https://i.weread.qq.com/config?token=1','GET','native_time_config'),
        native('https://i.weread.qq.com/feature?synckey=0','GET','native_time_feature'),
        native('https://i.weread.qq.com/readdata/detail?mode=monthly&baseTime=1698796800','GET','native_time_statistics'),
        web('https://weread.qq.com/api/userInfo?userVid=900000','GET',nil,'source_currentness',true),
        web(Protocol.reader_url('900001','11'),'GET',nil,'source_currentness'),
        web('https://weread.qq.com/web/book/getProgress?bookId=900001&_=1700000000000','GET',nil,'shelf_progress'),
        web('https://weread.qq.com/web/book/chapterInfos','POST',client:json_encode({bookIds={'900001'}}),'source_currentness'),
    }
    local params=Protocol.make_content_params('900001','11','synthetic-session',{sc=1,ct=1700000000})
    for _,name in ipairs({'e_0','e_1','e_3'}) do
        reads[#reads+1]=web('https://weread.qq.com/web/book/chapter/'..name,'POST',client:json_encode(params),'source_currentness')
    end
    for _,request in ipairs(reads) do local _,code=client:request(request);expect(code==200) end
    expect(state.calls==#reads and not guard.write_attempted and #state.events==0)
    local blocked={}
    local function add(request) blocked[#blocked+1]=request end
    add(native('https://i.weread.qq.com/login','POST','native_time_write',client:json_encode({})))
    add(native('https://i.weread.qq.com/book/getProgress?bookId=900002','GET','native_time_progress'))
    add(native('https://i.weread.qq.com/readdata/detail?mode=monthly&baseTime=1698796801','GET','native_time_statistics'))
    add(native('https://evil.invalid/book/batchUploadProgress','POST','native_time_write',client:json_encode({})))
    add(web('https://weread.qq.com/web/book/chapterInfos','POST',client:json_encode({bookIds={'900002'}}),'source_currentness'))
    local bad=F.clone(params);bad.c=Protocol.e('12')
    add(web('https://weread.qq.com/web/book/chapter/e_0','POST',client:json_encode(bad),'source_currentness'))
    bad=F.clone(params);bad.s='changed'
    add(web('https://weread.qq.com/web/book/chapter/e_0','POST',client:json_encode(bad),'source_currentness'))
    local extra=F.clone(reads[1]);extra.redirect=true;add(extra)
    extra=F.clone(reads[1]);extra.headers.Cookie='synthetic';add(extra)
    extra=F.clone(reads[1]);extra.headers['X-Extra']='synthetic';add(extra)
    extra=F.clone(reads[1]);extra.headers['User-Agent']='bad\r\nInjected: value';add(extra)
    extra=F.clone(reads[7]);extra.headers['X-Vid']='900001';add(extra)
    extra=F.clone(reads[9]);extra.url=extra.url..'&redirect=1';add(extra)
    for _,request in ipairs(blocked) do expect(not pcall(client.request,client,request)) end
    expect(state.calls==#reads and #state.events==0)
    local write=native('https://i.weread.qq.com/book/batchUploadProgress','POST','native_time_write',client:json_encode({books={}}))
    local _,code=client:request(write);expect(code==200 and state.calls==#reads+1)
    expect(guard.write_attempted and guard.write_forwarded and guard.acknowledged)
    expect(#state.events==2 and state.events[1].kind=='claim' and state.events[2].kind=='ack' and state.events[2].value.status==200)
    expect(not pcall(client.request,client,write) and state.calls==#reads+1)
end

for _,mode in ipairs({'denied','status','invalid_ack','throw','mismatch','oversized'}) do
    local client,guard,state,native=fixture({deny=mode=='denied',code=mode=='status' and 201 or nil,
        response=mode~='invalid_ack',throw=mode=='throw',mismatch=mode=='mismatch',oversized=mode=='oversized'})
    local write=native('https://i.weread.qq.com/book/batchUploadProgress','POST','native_time_write',client:json_encode({books={}}))
    expect(not pcall(client.request,client,write));expect(guard.write_attempted and not guard.acknowledged)
    expect(state.calls==(mode=='denied' and 0 or 1))
    expect(not pcall(client.request,client,write) and state.calls==(mode=='denied' and 0 or 1))
end

do
    local client,guard,state,native=fixture();state.current=false
    local value=native('https://i.weread.qq.com/shelf/sync','GET','native_shelf')
    expect(not pcall(client.request,client,value) and state.calls==0 and not guard.write_attempted)
end
for _,mode in ipairs({'grant','cookie'}) do
    local client,guard,state,native,_,grant,cookies=fixture()
    if mode=='grant' then grant.accessToken='changed-synthetic' else cookies.wr_skey='changed-synthetic' end
    local value=native('https://i.weread.qq.com/shelf/sync','GET','native_shelf')
    expect(not pcall(client.request,client,value) and state.calls==0 and not guard.write_attempted)
end
print('native_time_http_guard_spec: '..checks..' checks')
