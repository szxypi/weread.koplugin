-- Private validation transport for one native historical-time worker.
-- The caller must provide an authenticated IPC callback and disposable client.
local Protocol=require('weread.lib.protocol')
local Cookie=require('weread.lib.cookie')
local Position=require('weread.lib.native_position_protocol')
local Contract=require('weread.lib.readtime_transfer_contract')
local M={}
local NATIVE='https://i.weread.qq.com'
local WEB='https://weread.qq.com'
local function fail(reason) error('native_time_http/'..reason,0) end
local function exact(value,keys)
    if type(value)~='table' then return false end
    for key in pairs(value) do if not keys[key] then return false end end
    for key in pairs(keys) do if value[key]==nil then return false end end
    return true
end
local function headers(value)
    if type(value)~='table' then fail('headers') end
    local result={}
    for key,item in pairs(value) do
        if type(key)~='string' or not key:match('^[%w%-]+$') or type(item)~='string'
            or #item>32768 or item:find('[%z\r\n]') then fail('headers') end
        local name=key:lower();if result[name]~=nil then fail('headers') end;result[name]=item
    end
    return result
end
local function decoded(client,body)
    if type(body)~='string' or #body>65536 then fail('body') end
    local ok,value=pcall(client.json_decode,client,body)
    if not ok or type(value)~='table' then fail('body') end
    return value
end
local CONTENT_KEYS={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
local OPTION_KEYS={url=true,method=true,body=true,headers=true,skip_cookie=true,persist_response_cookies=true,
    sensitive=true,diagnostic_api=true,timeout=true,sink=true}

function M.install(client,config)
    local imported=type(config)=='table' and config.imported==true
    local book_valid=type(config)=='table' and (imported and Contract.cb_id(config.book_id)
        or not imported and Position.id(config.book_id) and Position.id(config.book_id)==config.book_id)
    if type(client)~='table' or type(client.request)~='function' or type(client.json_decode)~='function'
        or type(config)~='table' or config.imported~=nil and type(config.imported)~='boolean'
        or not Position.credentials(config.grant) or not book_valid
        or not Position.id(config.chapter_uid)
        or config.chapter_uid~=Position.id(config.chapter_uid) or type(config.cookies)~='table'
        or config.cookies.wr_vid~=config.grant.vid or type(config.cookies.wr_skey)~='string'
        or type(config.current)~='function' or type(config.rpc)~='function' or type(config.record)~='function'
        or type(config.selection)~='function' or not Contract.array(config.months,1,2) or type(config.now)~='function'
        or type(client.settings)~='table' or client.settings.mock_endpoint~=nil then fail('config') end
    for name,value in pairs(config.cookies) do
        if type(name)~='string' or not name:match('^[%w_]+$') or type(value)~='string'
            or #value<1 or #value>4096 or value:find('[^!-~]') or value:find('[;"\\]') then fail('config') end
    end
    local cookie=Cookie.to_header(config.cookies)
    if cookie=='' then fail('config') end
    local allowed_months,count={},0
    for _,month in ipairs(config.months) do
        if not Contract.integer(month,1,4102444800) or allowed_months[tostring(month)] then fail('config') end
        allowed_months[tostring(month)]=true;count=count+1
    end
    if count<1 or count>2 or count~=#config.months then fail('config') end
    local function binding()
        return Contract.digest({vid=config.grant.vid,accessToken=config.grant.accessToken,refreshToken=config.grant.refreshToken,
            deviceId=config.grant.deviceId,cookies=config.cookies,book_id=config.book_id,chapter_uid=config.chapter_uid,months=config.months,
            imported=config.imported==true})
    end
    local bound=binding()
    local original=client.request
    local state={requests=0,write_attempted=false,write_forwarded=false,acknowledged=false}
    local function current()
        if binding()~=bound then fail('session') end
        local ok,value=pcall(config.current)
        if not ok or value~=true or binding()~=bound then fail('session') end
    end
    local function web_headers(h,account)
        if h.cookie~=cookie or h.vid or h.accesstoken or h.authorization then fail('headers') end
        local allowed={cookie=true,origin=true,referer=true,accept=true,['content-type']=true,['x-vid']=true,['x-skey']=true}
        for key in pairs(h) do if not allowed[key] then fail('headers') end end
        if h.origin~=WEB then fail('headers') end
        if account then
            if h['x-vid']~=config.grant.vid or h['x-skey']~=config.cookies.wr_skey then fail('headers') end
        elseif h['x-vid'] or h['x-skey'] then fail('headers') end
    end
    local function native_headers(h)
        if h.vid~=config.grant.vid or h.accesstoken~=config.grant.accessToken
            or h.cookie or h.authorization or h['x-vid'] or h['x-skey'] then fail('headers') end
        local allowed={vid=true,accesstoken=true,baseapi=true,appver=true,basever=true,osver=true,channelid=true,
                       accept=true,['user-agent']=true,['content-type']=true}
        for key in pairs(h) do if not allowed[key] then fail('headers') end end
    end
    local function content_body(body)
        local value=decoded(client,body)
        if not exact(value,CONTENT_KEYS) or value.b~=Protocol.e(config.book_id) or value.c~=Protocol.e(config.chapter_uid)
            or type(value.r)~='string' or #value.r>32 or not value.r:match('^%d+$')
            or type(value.ct)~='string' or not value.ct:match('^%d+$') or #value.ct>12
            or math.abs(tonumber(value.ct)-config.now())>60 or value.pc~=Protocol.e(value.ct)
            or type(value.ps)~='string' or #value.ps<1 or #value.ps>4096 or value.ps:find('[^!-~]')
            or value.sc~=1 or value.prevChapter~=false or value.st~=0
            or value.s~=Protocol.sign(Protocol.sorted_query(value)) then fail('body') end
    end
    local function permitted(options,h)
        local url,method,api=options.url,options.method,options.diagnostic_api
        local book=config.book_id
        if type(url)~='string' or type(method)~='string' or type(api)~='string' then fail('route') end
        if url==NATIVE..'/book/batchUploadProgress' then
            if method~='POST' or api~='native_time_write' then fail('route') end
            native_headers(h);return 'write'
        end
        if method=='GET' and options.body==nil then
            if api=='native_time_metadata' and url==NATIVE..'/book/info?bookId='..book
                or api=='native_time_progress' and url==NATIVE..'/book/getProgress?bookId='..book
                or api=='native_shelf' and url==NATIVE..'/shelf/sync'
                or api=='native_time_config' and url==NATIVE..'/config?token=1'
                or api=='native_time_feature' and url==NATIVE..'/feature?synckey=0' then
                native_headers(h);return 'read'
            end
            local month=url:match('^https://i%.weread%.qq%.com/readdata/detail%?mode=monthly&baseTime=(%d+)$')
            if api=='native_time_statistics' and month and allowed_months[month] then native_headers(h);return 'read' end
            if api=='source_currentness' and url==WEB..'/api/userInfo?userVid='..config.grant.vid then
                web_headers(h,true);return 'read'
            end
            if api=='source_currentness' and url==Protocol.reader_url(book,config.chapter_uid) then
                web_headers(h,false);return 'read'
            end
            local prefix=WEB..'/web/book/getProgress?bookId='..book..'&_='
            if api=='shelf_progress' and url:sub(1,#prefix)==prefix then
                local stamp=url:sub(#prefix+1)
                if #stamp<10 or #stamp>16 or not stamp:match('^%d+$') or math.abs(tonumber(stamp)/1000-config.now())>60 then fail('route') end
                web_headers(h,false);return 'read'
            end
        end
        if method=='POST' and api=='source_currentness' then
            web_headers(h,false)
            if url==WEB..'/web/book/chapterInfos' then
                local value=decoded(client,options.body)
                if not exact(value,{bookIds=true}) or type(value.bookIds)~='table' or #value.bookIds~=1
                    or value.bookIds[1]~=book then fail('body') end
                for key in pairs(value.bookIds) do if key~=1 then fail('body') end end
                return 'read'
            end
            if url==WEB..'/web/book/chapter/e_0' or url==WEB..'/web/book/chapter/e_1' or url==WEB..'/web/book/chapter/e_3' then
                content_body(options.body);return 'read'
            end
        end
        fail('route')
    end
    client.request=function(self,options)
        if self~=client or type(options)~='table' then fail('options') end
        for key in pairs(options) do if not OPTION_KEYS[key] then fail('options') end end
        if options.skip_cookie~=true or options.persist_response_cookies~=false or options.sensitive~=true
            or type(options.sink)~='function' then fail('options') end
        current();local h=headers(options.headers);local kind=permitted(options,h)
        state.requests=state.requests+1;if state.requests>100 then fail('limit') end
        if kind~='write' then
            local safe={};for key,value in pairs(options) do safe[key]=value end;safe.redirect=false
            local raw,code,response_headers,status=original(self,safe)
            current();return raw,code,response_headers,status
        end
        if state.write_attempted then fail('replay') end
        state.write_attempted=true
        local body=decoded(client,options.body);local record=config.record();local selection=config.selection()
        if type(record)~='table' or record.phase~='claimed' or type(selection)~='table' then fail('record') end
        if config.rpc('claim',{body=body,selection=selection,record=record})~=true then fail('denied') end
        current();state.write_forwarded=true
        local chunks,size={},0;local sink=options.sink;local forwarded={}
        for key,value in pairs(options) do forwarded[key]=value end
        forwarded.redirect=false
        forwarded.sink=function(chunk,...)
            if chunk then
                if type(chunk)~='string' then return nil,'native_time_http/response' end
                size=size+#chunk;if size>65536 then return nil,'native_time_http/response' end
                chunks[#chunks+1]=chunk
            end
            return sink(chunk,...)
        end
        local raw,code,response_headers,status=original(self,forwarded)
        current()
        local captured=table.concat(chunks)
        if type(raw)=='string' and captured~='' and raw~=captured then fail('response') end
        if type(raw)~='string' then raw=captured end
        if size>65536 or #raw>65536 then fail('response') end
        local ok,response=pcall(client.json_decode,client,raw)
        if not ok or type(response)~='table' then response={} end
        local numeric=tonumber(code)
        if config.rpc('ack',{status=numeric or 0,response=response})~=true or numeric~=200 then fail('receipt') end
        state.acknowledged=true
        return raw,code,response_headers,status
    end
    return state
end
return M
