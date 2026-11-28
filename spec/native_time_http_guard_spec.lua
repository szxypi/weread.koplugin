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
        local account=request.url:find('/api/userInfo?',1,true) and options.account_response
        local text=account and self:json_encode({vid=options.wrong_owner and '900001' or grant.vid}) or reply
        local response_headers=account and {['set-cookie']=options.account_response} or {}
        request.sink(text);request.sink(nil)
        return options.mismatch and self:json_encode({succ=1}) or nil,options.code or 200,response_headers
    end
    local guard=Guard.install(client,{grant=grant,book_id=options.book or (options.imported and 'CB_Synthetic' or '900001'),imported=options.imported,
        native_direct=options.direct,position_write=options.position,book_version=options.version,
        chapter_uid='11',cookies=cookies,months={1698796800},now=function() return 1700000000 end,
        current=function() return state.current end,selection=function() return {synthetic=true} end,
        record=function() return {phase=options.position and 'pending' or 'claimed',synthetic=true} end,rpc=function(kind,value)
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
    expect(not pcall(fixture,{position=true}))
    local client,guard,state,native,web=fixture({direct=true,position=true,version=7})
    local reads={native('https://i.weread.qq.com/book/info?bookId=900001','GET','native_position_metadata'),
        native('https://i.weread.qq.com/book/getProgress?bookId=900001','GET','native_position_progress'),
        native('https://i.weread.qq.com/feature?synckey=0','GET','native_position_feature')}
    for _,request in ipairs(reads) do expect(select(2,client:request(request))==200) end
    local progress='https://weread.qq.com/web/book/getProgress?bookId=900001&_=1700000000000'
    expect(select(2,client:request(web(progress,'GET',nil,'source_currentness')))==200)
    expect(not pcall(client.request,client,web(progress:gsub('900001','900002'),'GET',nil,'source_currentness')))
    expect(not pcall(client.request,client,web(progress:gsub('1700000000000','1600000000000'),'GET',nil,'source_currentness')))
    local wrong=native('https://i.weread.qq.com/book/batchUploadProgress','POST','native_time_write',client:json_encode({}))
    expect(not pcall(client.request,client,wrong) and state.calls==4)
    local write=native('https://i.weread.qq.com/book/read','POST','native_position_write',client:json_encode({bookId='900001'}))
    expect(select(2,client:request(write))==200 and guard.acknowledged and state.calls==5)
    expect(#state.events==2 and state.events[1].kind=='claim' and state.events[2].kind=='ack')
    expect(not pcall(client.request,client,write) and state.calls==5)
    local time,_,time_state,time_native,time_web=fixture({direct=true,version=7})
    expect(not pcall(time.request,time,time_web(progress,'GET',nil,'source_currentness')))
    expect(not pcall(time.request,time,time_native('https://i.weread.qq.com/book/read','POST','native_position_write',time:json_encode({})))
        and time_state.calls==0)
end

do
    expect(not pcall(fixture,{direct=true}))
    expect(not pcall(fixture,{direct=true,version=1,imported=true}))
    local client,guard,state,native=fixture({direct=true,version=7})
    local body={bookIds={'900001'},synckeys={0},updateTimes={0},maxfreeIdx={0}}
    local download='https://i.weread.qq.com/book/chapterdownload?bookId=900001&chapters=0%2C11&bookType=epub&bookVersion=7'
        ..'&pf=wechat_wx-2001-android-100-weread&pfkey=pfKey&zoneId=1&quote=&release=1&stopAutoPayWhenBNE=1&preload=2&preview=0&offline=1'
    local reads={native('https://i.weread.qq.com/book/info?bookId=900001','GET','native_chapter_info'),
        native('https://i.weread.qq.com/book/chapterInfos','POST','native_chapter_catalog',client:json_encode(body)),
        native(download,'GET','native_chapter_download')}
    for _,request in ipairs(reads) do expect(select(2,client:request(request))==200) end
    local invalid={native(download:gsub('preview=0','preview=1'),'GET','native_chapter_download'),
        native(download:gsub('chapters=0%%2C11','chapters=0%%2C12'),'GET','native_chapter_download'),
        native(download:gsub('bookVersion=7','bookVersion=8'),'GET','native_chapter_download'),
        native('https://i.weread.qq.com/book/chapterInfos','POST','native_chapter_catalog',
            client:json_encode({bookIds={'900002'},synckeys={0},updateTimes={0},maxfreeIdx={0}}))}
    for _,request in ipairs(invalid) do expect(not pcall(client.request,client,request)) end
    expect(state.calls==#reads and not guard.write_attempted)
    local old,_,oldstate,oldnative=fixture()
    expect(not pcall(old.request,old,oldnative(download,'GET','native_chapter_download')) and oldstate.calls==0)
end

do
    local client,guard,state,_,web,grant,cookies=fixture({direct=true,version=7,account_response='wr_skey'..'=synthetic-rotated; Path=/'})
    local account=web('https://weread.qq.com/api/userInfo?userVid=900000','GET',nil,'source_currentness',true)
    expect(select(2,client:request(account))==200)
    local rotated=F.clone(cookies);rotated.wr_skey='synthetic-rotated'
    local reader=web(Protocol.reader_url('900001','11'),'GET',nil,'source_currentness')
    reader.headers.Cookie=Cookie.to_header(rotated)
    expect(select(2,client:request(reader))==200 and state.calls==2 and not guard.write_attempted)
    reader.headers.Cookie=reader.headers.Cookie..'; injected=1'
    expect(not pcall(client.request,client,reader) and state.calls==2)
    local bad,badguard,badstate,_,badweb=fixture({direct=true,version=7,wrong_owner=true,account_response='wr_skey'..'=synthetic-rotated; Path=/'})
    expect(not pcall(bad.request,bad,badweb('https://weread.qq.com/api/userInfo?userVid=900000','GET',nil,'source_currentness',true))
        and badstate.calls==1 and not badguard.write_attempted)
    local duplicate,_,duplicate_state,_,duplicate_web=fixture({direct=true,version=7,
        account_response={'wr_skey'..'=synthetic-one; Path=/','wr_skey'..'=synthetic-two; Path=/'}})
    expect(not pcall(duplicate.request,duplicate,duplicate_web('https://weread.qq.com/api/userInfo?userVid=900000','GET',nil,'source_currentness',true))
        and duplicate_state.calls==1)
    expect(grant.vid==cookies.wr_vid and cookies.wr_skey=='synthetic-cookie','rotation changed captured session')
end

do
    expect(not pcall(fixture,{book='CB_Synthetic'}))
    expect(not pcall(fixture,{book='900001',imported=true}))
    expect(not pcall(fixture,{book='CB_bad/',imported=true}))
    expect(not pcall(fixture,{imported='yes'}))
    local client,guard,state,native,web=fixture({imported=true})
    local read=native('https://i.weread.qq.com/book/info?bookId=CB_Synthetic','GET','native_time_metadata')
    local progress=web('https://weread.qq.com/web/book/getProgress?bookId=CB_Synthetic&_=1700000000000','GET',nil,'shelf_progress')
    expect(select(2,client:request(read))==200 and select(2,client:request(progress))==200)
    local wrong=native('https://i.weread.qq.com/book/info?bookId=CB_Other','GET','native_time_metadata')
    expect(not pcall(client.request,client,wrong) and state.calls==2 and not guard.write_attempted)
    local write=native('https://i.weread.qq.com/book/batchUploadProgress','POST','native_time_write',client:json_encode({books={}}))
    expect(select(2,client:request(write))==200 and guard.acknowledged and state.calls==3)
    expect(not pcall(client.request,client,write) and state.calls==3)
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
