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
    local direct=type(config)=='table' and config.native_direct==true
    local txt=type(config)=='table' and config.native_txt==true
    local position=type(config)=='table' and config.position_write==true
    local book_valid=type(config)=='table' and (imported and Contract.cb_id(config.book_id)
        or not imported and Position.id(config.book_id) and Position.id(config.book_id)==config.book_id)
    if type(client)~='table' or type(client.request)~='function' or type(client.json_decode)~='function'
        or type(config)~='table' or config.imported~=nil and type(config.imported)~='boolean'
        or config.native_direct~=nil and type(config.native_direct)~='boolean' or direct and imported
        or config.position_write~=nil and type(config.position_write)~='boolean' or position and not direct
        or config.native_txt~=nil and type(config.native_txt)~='boolean'
        or txt and (not direct or position or config.book_version~=0)
        or direct and not txt and not Contract.integer(config.book_version,1,2147483647)
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
    local cookie=Cookie.to_header(config.cookies);local rotated_cookie,rotated_key
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
            imported=config.imported==true,native_direct=direct,native_txt=txt,position_write=position,book_version=config.book_version})
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
        local key=h.cookie==cookie and config.cookies.wr_skey
            or direct and rotated_cookie and h.cookie==rotated_cookie and rotated_key
        if not key or h.vid or h.accesstoken or h.authorization then fail('headers') end
        local allowed={cookie=true,origin=true,referer=true,accept=true,['content-type']=true,['x-vid']=true,['x-skey']=true}
        for header in pairs(h) do if not allowed[header] then fail('headers') end end
        if h.origin~=WEB then fail('headers') end
        if account then
            if h['x-vid']~=config.grant.vid or h['x-skey']~=key then fail('headers') end
        elseif h['x-vid'] or h['x-skey'] then fail('headers') end
    end
    local function capture_rotation(raw,code,response_headers)
        if not direct or tonumber(code)~=200 then return end
        local ok,value=pcall(client.json_decode,client,raw)
        if not ok or type(value)~='table' or Position.id(value.vid or value.userVid)~=config.grant.vid
            or value.vid and value.userVid and Position.id(value.vid)~=Position.id(value.userVid)
            or value.errcode and value.errcode~=0 and value.errcode~='0'
            or value.errCode and value.errCode~=0 and value.errCode~='0' then fail('session') end
        local cookies
        for key,item in pairs(response_headers or {}) do
            if type(key)=='string' and key:lower()=='set-cookie' then
                if cookies~=nil then fail('headers') end;cookies=item
            end
        end
        rotated_cookie,rotated_key=nil,nil
        if cookies==nil then return end
        if type(cookies)=='string' then cookies={cookies} end
        if type(cookies)~='table' or #cookies>32 then fail('headers') end
        local access,key_count,vid_count=nil,0,0
        for index,line in pairs(cookies) do
            if type(index)~='number' or index%1~=0 or index<1 or index>#cookies
                or type(line)~='string' or #line>16384 then fail('headers') end
            for name,item in line:gmatch('([%w_]+)=([^;,\r\n]*)') do
                if name=='wr_vid' then
                    vid_count=vid_count+1;if vid_count>1 or item~=config.grant.vid then fail('headers') end
                elseif name=='wr_skey' then
                    key_count=key_count+1
                    if key_count>1 or #item<8 or #item>4096 or item:find('[%z%c%s;"\\]') or item:find('[\128-\255]') then fail('headers') end
                    access=item
                end
            end
        end
        if access then
            local copy={};for key,item in pairs(config.cookies) do copy[key]=item end
            copy.wr_skey=access;rotated_key=access;rotated_cookie=Cookie.to_header(copy)
        end
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
        if url==NATIVE..'/book/batchUploadProgress' or url==NATIVE..'/book/read' then
            if position then
                if url~=NATIVE..'/book/read' or method~='POST' or api~='native_position_write' then fail('route') end
            elseif url~=NATIVE..'/book/batchUploadProgress' or method~='POST' or api~='native_time_write' then fail('route') end
            native_headers(h);return 'write'
        end
        if method=='GET' and options.body==nil then
            if direct and api=='native_chapter_info' and url==NATIVE..'/book/info?bookId='..book then
                native_headers(h);return 'read'
            end
            if position and (api=='native_position_metadata' and url==NATIVE..'/book/info?bookId='..book
                or api=='native_position_progress' and url==NATIVE..'/book/getProgress?bookId='..book
                or api=='native_position_feature' and url==NATIVE..'/feature?synckey=0') then
                native_headers(h);return 'read'
            end
            if direct and api=='native_chapter_download' then
                local fields={{'bookId',book},{'chapters',txt and config.chapter_uid or '0,'..config.chapter_uid},
                    {'bookType',txt and 'txt' or 'epub'},
                    {'bookVersion',config.book_version},{'pf','wechat_wx-2001-android-100-weread'},{'pfkey','pfKey'},
                    {'zoneId',1},{'quote',''},{'release',1},{'stopAutoPayWhenBNE',1},{'preload',2},{'preview',0},{'offline',1}}
                local encoded={};for _,field in ipairs(fields) do encoded[#encoded+1]=field[1]..'='..Protocol.urlencode(tostring(field[2])) end
                if url~=NATIVE..'/book/chapterdownload?'..table.concat(encoded,'&') then fail('route') end
                native_headers(h);return 'read'
            end
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
            if (api=='shelf_progress' or position and api=='source_currentness') and url:sub(1,#prefix)==prefix then
                local stamp=url:sub(#prefix+1)
                if #stamp<10 or #stamp>16 or not stamp:match('^%d+$') or math.abs(tonumber(stamp)/1000-config.now())>60 then fail('route') end
                web_headers(h,false);return 'read'
            end
        end
        if direct and method=='POST' and api=='native_chapter_catalog' and url==NATIVE..'/book/chapterInfos' then
            native_headers(h);local value=decoded(client,options.body)
            local keys={bookIds=true,synckeys=true,updateTimes=true,maxfreeIdx=true}
            if not exact(value,keys) then fail('body') end
            for key in pairs(keys) do
                local array=value[key]
                if type(array)~='table' or #array~=1 or array[1]~=(key=='bookIds' and book or 0) then fail('body') end
                for index in pairs(array) do if index~=1 then fail('body') end end
            end
            return 'read'
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
            if url==WEB..'/web/book/chapter/e_0'
                or txt and (url==WEB..'/web/book/chapter/t_0' or url==WEB..'/web/book/chapter/t_1')
                or not txt and (url==WEB..'/web/book/chapter/e_1' or url==WEB..'/web/book/chapter/e_3') then
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
            local account_response=direct and options.diagnostic_api=='source_currentness'
                and options.url==WEB..'/api/userInfo?userVid='..config.grant.vid
            local captured,size={},0
            if account_response then
                local sink=options.sink
                safe.sink=function(chunk,...)
                    if chunk then size=size+#chunk;if size>65536 then return nil,'native_time_http/response' end;captured[#captured+1]=chunk end
                    return sink(chunk,...)
                end
            end
            local raw,code,response_headers,status=original(self,safe)
            if account_response then capture_rotation(type(raw)=='string' and raw or table.concat(captured),code,response_headers) end
            current();return raw,code,response_headers,status
        end
        if state.write_attempted then fail('replay') end
        state.write_attempted=true
        local body=decoded(client,options.body);local record=config.record();local selection=config.selection()
        if type(record)~='table' or record.phase~=(position and 'pending' or 'claimed') or type(selection)~='table' then fail('record') end
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
