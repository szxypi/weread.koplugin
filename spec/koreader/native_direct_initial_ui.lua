-- Actual installed plugin and ReaderUI; all writes require the host broker.
require('jit').off();require('ffi').log=function() end;require('setupkoenv');require('ffi/posix_h')
local ffi=require('ffi');local json=require('json')
local size=assert(tonumber(io.stdin:read('*l')));assert(size>0 and size<=262144)
local input=json.decode(assert(io.stdin:read(size)));local token=assert(input.rpc_token)
assert(token:match('^[a-f0-9]+$') and #token==32 and type(input.armed)=='boolean')
local function emit(kind,value)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_'..kind..'='..json.encode(value)..'\n');io.stdout:flush()
end
local function rpc(kind,value)
    value=value or {};value.kind=kind;emit('STEP',value)
    local reply=json.decode(assert(io.stdin:read('*l')))
    assert(reply.kind==kind and type(reply.ok)=='boolean');return reply.ok
end
local worked,reason=xpcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
    local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..assert(arg[1])..'/?.lua;'..package.path
    local P=require('weread.lib.native_position_protocol')
    assert(P.id(input.book_id)==input.book_id and input.credentials.vid==input.cookies.wr_vid)
    assert(P.integer(input.book_version,1,2147483647) and P.id(input.chapter_uid)==input.chapter_uid)
    if input.mock_endpoint then
        assert(input.mock_endpoint:match('^http://127%.0%.0%.1:%d+$') and input.credentials.vid=='12345678'
            and input.book_id=='42' and input.credentials.accessToken=='synthetic-access'
            and input.cookies.wr_skey=='synthetic-web-access')
    end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.credentials.vid,name=''},cookies=input.cookies,api_key=''}
    local fd=tonumber(ffi.C.memfd_create('weread-initial-auth',1));assert(fd>=0)
    local encoded='return '..require('dump')(auth,nil,true);local at=0
    while at<#encoded do
        local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',encoded)+at,#encoded-at));assert(n>0);at=at+n
    end
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Settings=require('weread.lib.settings');local original_new=Settings.new
    function Settings:new()
        local value=original_new(self);local flush=value.store.flush
        function value.store.flush(store,...)
            local held={};local keys={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _,key in ipairs(keys) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for key,item in pairs(held) do store.data[key]=item end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value.settings_file='/proc/self/fd/'..fd
        local sync=value:get('sync',{});sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
        local cache=value:get('cache',{});cache.show_annotations=false;cache.auto_prefetch_next_chapter=false;value:set('cache',cache)
        local report=value:get('read_report',{});report.enabled=false;value:set('read_report',report)
        return value
    end
    local credentials={read=function() return input.credentials,1,nil,false end}
    local Access=require('weread.lib.native_read_access');local capture=Access.capture
    Access.capture=function(settings,existing) return capture(settings,existing or credentials) end
    local Client=require('weread.lib.client');local original_request=Client.request;local allowed_client
    function Client:request(options)
        assert(self==allowed_client,'initial_ui/other_client')
        if input.mock_endpoint then
            self.settings.mock_endpoint=input.mock_endpoint
            local values={pcall(original_request,self,options)};self.settings.mock_endpoint=nil
            assert(values[1]);return unpack(values,2)
        end
        return original_request(self,options)
    end
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('initial_ui/screenshot_disabled',0) end
    local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
    for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
    assert(#loader.enabled_plugins==1)
    local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
    local function wait(predicate)
        local deadline=socket.gettime()+180
        while not predicate() do assert(socket.gettime()<deadline,'initial_ui/timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.weread end)
    local reader=Reader.instance;local host=reader.weread
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    host.isNetworkConnected=function() return true end;host.showInfo=function(self,message) self.checked_message=message end
    local account=host.library_db:accountKey();assert(account==require('weread.lib.native_position_contract').account_key(input.credentials.vid))
    local service,metadata,anchor,background;allowed_client=host.client
    local guard=require('spec.koreader.native_time_http_guard').install(host.client,{
        grant=input.credentials,book_id=input.book_id,chapter_uid=input.chapter_uid,book_version=input.book_version,
        native_direct=true,position_write=true,cookies=input.cookies,months=input.months,now=os.time,
        current=function() return host._native_direct_position~=nil end,selection=function() return metadata end,
        record=function() local record=assert(service.journal:read());assert(record.phase=='pending');return record end,
        rpc=function(kind,value) return rpc(kind,value) end})
    if input.mock_endpoint then
        local guarded=host.client.request
        host.client.request=function(client,options)
            local result={pcall(guarded,client,options)}
            if not result[1] then
                local file=assert(io.open(home..'/synthetic-guard-error','w'))
                file:write(tostring(result[2]),' ',tostring(options.method),' ',tostring(options.diagnostic_api),' ',tostring(options.url));file:close()
                error(result[2],0)
            end
            return unpack(result,2)
        end
    end
    local worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=65536,timeout=180}
    host._native_direct_position_worker={cancel=function() worker:cancel() end,start=function(_,task,callback)
        local ctx=assert(host._native_direct_position);anchor={text=ctx.input.text,point_offset=ctx.input.point_offset}
        return worker:start(task,function(value)
            if input.mock_endpoint and type(value)=='table' then host.synthetic_worker_error=value.error end
            return callback(value)
        end)
    end}
    local Service=require('weread.lib.native_position_service');local start=Service.start
    function Service:start(value,check,callback)
        assert(not service and anchor and require('weread.lib.native_position_contract').valid(value))
        service,metadata=self,value
        assert(rpc('plan',{metadata=value,anchor=anchor}),'initial_ui/plan')
        local started,why=start(self,value,check,callback)
        if started then
            local job=assert(self.worker and self.worker.job)
            assert(type(job.pid)=='number' and job.pid~=tonumber(ffi.C.getpid()));background=true
        end
        return started,why
    end
    assert(host:onShowWeReadQuickMenu())
    wait(function() local top=UI:getTopmostVisibleWidget();return top and type(top.getButtonById)=='function'
        and top:getButtonById('native_upload_position')~=nil end)
    UI:forceRePaint();assert(UI:getTopmostVisibleWidget():getButtonById('native_upload_position')):onTapSelectButton()
    wait(function() return host.checked_message or host._native_direct_position and host._native_direct_position.confirm end)
    if input.mock_endpoint and host.checked_message then
        local file=io.open(home..'/synthetic-guard-error','r');local detail=file and file:read('*a') or 'no_guard_error'
        if file then file:close() end
        error('synthetic: '..tostring(host.checked_message)..' / '..tostring(host.synthetic_worker_error)..' / '..detail)
    end
    local ctx=assert(host._native_direct_position);local confirm=assert(ctx.confirm)
    local tr=require('weread.lib.plugin_util').tr
    assert(confirm.text==tr('WeRead has no cloud position for this book. Set this page as its first position? Existing reading time will be kept.'))
    confirm.ok_callback();wait(function() return host.checked_message~=nil end)
    local expected=input.armed and 'Cloud reading position synced and checked.'
        or 'The sync result could not be confirmed. Choose sync again to review it.'
    assert(host.checked_message==tr(expected),'initial_ui/result')
    local pending=service:pending()
    assert(background and guard and (input.armed and not pending or not input.armed and pending and pending.phase=='pending'))
    if input.armed then assert(rpc('verified',{}),'initial_ui/verified') end
    reader:onClose(false)
    local status=ffi.new('int[1]')
    wait(function() local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
        while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end;return child==-1 end)
    emit('RESULT',{result='PASS',native_ui=true,background_service=true,blocked=not input.armed,workers_reaped=true})
end,function(err) return debug.traceback(tostring(err),2) end)
if not worked then
    local file,line
    if type(reason)=='string' then file,line=reason:match('([%w_%-]+%.lua):(%d+):') end
    local result={result='UNVERIFIED',failed_module=file or 'unknown',failed_line=tonumber(line) or 0}
    if input.mock_endpoint then result.synthetic_error=reason end
    emit('RESULT',result)
    os.exit(1)
end
