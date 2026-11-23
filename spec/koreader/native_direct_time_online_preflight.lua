-- Real production time task, with a read-only HTTP allowlist and a journal
-- that refuses to create a dispatch record. Credentials remain in memory.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
local ffi=require('ffi');local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
assert(type(input.credentials)=='table' and type(input.cookies)=='table' and input.cookies.wr_vid==input.credentials.vid)
pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.credentials.vid,name=''},cookies=input.cookies,api_key=''}
local fd=tonumber(ffi.C.memfd_create('weread-time-auth',1));assert(fd>=0)
local encoded='return '..require('dump')(auth,nil,true);local offset=0
while offset<#encoded do
    local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',encoded)+offset,#encoded-offset));assert(n>0);offset=offset+n
end
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local Settings=require('weread.lib.settings');local new=Settings.new
function Settings:new()
    local value=new(self);local flush=value.store.flush
    value.store.flush=function(store,...)
        local held={};local keys={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
        for _,key in ipairs(keys) do held[key]=store.data[key];store.data[key]=nil end
        local result={pcall(flush,store,...)}
        for _,key in ipairs(keys) do store.data[key]=held[key] end
        assert(result[1]);return unpack(result,2)
    end
    for key,item in pairs(auth) do value.store:saveSetting(key,item) end
    value.settings_file='/proc/self/fd/'..fd
    if type(input.mock_endpoint)=='string' then value.mock_endpoint=input.mock_endpoint end
    return value
end
local settings=Settings:new();local scope=assert(settings:get_auth_scope())
local account=require('weread.lib.native_position_contract').account_key(scope.vid)
local credentials={read=function() return input.credentials,1,nil,false end}
local Native=require('weread.lib.native_read_access');local Web=require('weread.lib.read_access')
local native=assert(Native.capture(settings,credentials));local web=assert(Web.capture(settings))
local Client=require('weread.lib.client');local client=Client:new(settings);local request=client.request
local Protocol=require('weread.lib.protocol');local base='https://i.weread.qq.com';local website='https://weread.qq.com'
local last='none';local count=0;local blocked=0;local rejected='none';local last_status=0;local transport='none';local error_line=0
function client:request(options)
    local url=options.url;local method=options.method or 'GET';local route
    if url==base..'/book/info?bookId='..input.book_id and method=='GET' then route='metadata'
    elseif url==base..'/book/getProgress?bookId='..input.book_id and method=='GET' then route='native_progress'
    elseif url==base..'/shelf/sync' and method=='GET' then route='shelf'
    elseif type(url)=='string' and url:match('^https://i%.weread%.qq%.com/readdata/detail%?mode=monthly&baseTime=%d+$') and method=='GET' then route='statistics'
    elseif url==base..'/config?token=1' and method=='GET' then route='config'
    elseif url==base..'/feature?synckey=0' and method=='GET' then route='feature'
    elseif url==base..'/book/chapterInfos' and method=='POST' then
        local body=json.decode(options.body);assert(#body.bookIds==1 and body.bookIds[1]==input.book_id
            and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0);route='native_catalog'
    elseif type(url)=='string' and url:find(base..'/book/chapterdownload?',1,true)==1 and method=='GET'
        and url:find('bookId='..input.book_id..'&',1,true) and url:find('chapters=0%2C'..input.uid..'&',1,true)
        and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true) then route='native_source'
    elseif url==website..'/api/userInfo?userVid='..input.credentials.vid and method=='GET' then route='user'
    elseif type(url)=='string' and method=='GET'
        and (url==website..'/web/book/getProgress?bookId='..input.book_id
            or url:match('^https://weread%.qq%.com/web/book/getProgress%?bookId='..input.book_id..'&_=%d+$')) then route='web_progress'
    elseif url==website..'/web/book/chapterInfos' and method=='POST' then
        local body=json.decode(options.body);assert(#body.bookIds==1 and body.bookIds[1]==input.book_id)
        for key in pairs(body) do assert(key=='bookIds') end;route='web_catalog'
    elseif (url==Protocol.reader_url(input.book_id) or url==Protocol.reader_url(input.book_id,input.uid)) and method=='GET' then route='reader'
    elseif (url==website..'/web/book/chapter/e_0' or url==website..'/web/book/chapter/e_1' or url==website..'/web/book/chapter/e_3') and method=='POST' then
        local body=json.decode(options.body);assert(body.b==Protocol.e(input.book_id) and body.c==Protocol.e(input.uid)
            and body.sc==1 and body.prevChapter==false and body.st==0);route='web_source'
    end
    if not route then
        blocked=blocked+1
        if type(url)=='string' then
            for _,key in ipairs({'book/info','book/getProgress','shelf/sync','readdata/detail','config','feature',
                'book/chapterInfos','book/chapterdownload','api/userInfo','web/book/getProgress','web/book/chapterInfos',
                'web/reader/','web/book/chapter/e_','book/batchUploadProgress'}) do
                if url:find('/'..key,1,true) then rejected=key:gsub('[^a-zA-Z]','_');break end
            end
        end
        error('read_only_scope',0)
    end
    count=count+1;assert(count<=100);last=route
    local ok,a,b,c=pcall(request,self,options)
    if not ok then
        last_status=-1
        if type(a)=='string' and a:find('sensitive_request_failed',1,true) then transport='sensitive_request_failed'
        else
            transport='other'
            if type(a)=='string' then error_line=tonumber(a:match('client%.lua:(%d+)')) or 0 end
        end
        error('read_failed',0)
    end
    last_status=type(b)=='number' and b or tonumber(b) or 0
    return a,b,c
end
local write_ok=pcall(client.request,client,{url=base..'/book/batchUploadProgress',method='POST',body='{}'})
assert(not write_ok and blocked==1 and rejected=='book_batchUploadProgress' and count==0,'write guard failed')
blocked=0;rejected='none'
local ledger=require('weread.lib.offline_time_store'):new(settings.data_dir)
local coverage=require('weread.lib.readtime_coverage'):new(settings.data_dir)
local selection=assert(require('weread.lib.readtime_transfer_queue'):new{ledger=ledger,coverage=coverage}
    :select(account,input.book_id,{current_day=true,allow_native=true})).selection
assert(selection and selection.current_day and selection.native_direct and selection.seconds>=5)
local rows=assert(ledger:pending(account));local digest=require('weread.lib.readtime_transfer_contract').digest
local before=digest(rows)
local cursor,prior=1,nil;local found
repeat
    found=require('weread.lib.native_direct_readtime_source').scan_page(settings,account,scope,selection,cursor,prior,function() return true end)
    if found.kind=='more' then cursor,prior=found.cursor,found.prior end
until found.kind~='more'
assert(found.kind=='found')
local journal=require('weread.lib.readtime_transfer_store'):new{ledger=ledger,coverage=coverage,codec=client}
local begin=journal.begin;local reached=false
journal.begin=function(_self,owner,batch,metadata)
    assert(not reached and owner==account and digest(batch)==digest(selection) and metadata.seconds==selection.seconds
        and metadata.protocol=='native-current-time-cst-v1' and metadata.source.file_id==selection.file_id
        and type(metadata.request_hash)=='string' and #metadata.request_hash==64)
    reached=true;return nil
end
local Source=require('weread.lib.native_direct_readtime_source');local observe=Source.observe;local source_reason='none'
Source.observe=function(...)
    local value,reason=observe(...)
    if not value and ({invalid=true,file_changed=true,source_changed=true,unavailable=true,web_expired=true,
        auth_expired=true,not_entitled=true,rate_limited=true,session_changed=true})[reason] then source_reason=reason end
    return value,reason
end
local Point=require('weread.lib.readtime_point');local point_hash=Point.hash;local point_failure='none'
Point.hash=function(raw,book,kind)
    local ok,value=pcall(point_hash,raw,book,kind)
    if not ok then
        local projected,reason,fields=require('weread.lib.remote_progress').project(raw,book,kind)
        local problem
        if reason or not projected then problem='invalid'
        elseif not fields.chapter_uid or not fields.chapter_idx or not fields.chapter_offset then problem='missing'
        elseif not require('weread.lib.native_position_protocol').id(projected.chapter_uid) then problem='no_chapter'
        else problem='other' end
        point_failure=(kind=='native' and 'native_' or 'web_')..problem
        error('time_point_rejected',0)
    end
    return value
end
local result=require('weread.lib.readtime_transfer_task').run(client,settings,native,web,selection,{found.reference},journal,
    {account=account,allow_current_native=true,is_current=function() return true end})
journal.begin=begin
assert(not result.attempted and not result.acknowledged)
assert(digest(assert(ledger:pending(account)))==before and not journal:pending(account))
print('WEREAD_DIRECT_TIME_ONLINE='..json.encode{ok=reached and blocked==0,blocked_before_dispatch=true,ledger_unchanged=true,
    last=last,requests=count,rejected=rejected,last_status=last_status,source_reason=source_reason,transport=transport,
    error_line=error_line,point_failure=point_failure,write_guard_verified=true})
