-- A separately supervised actual ReaderUI time transfer. The host must
-- authorize each framed step; this process never grants its own send.
require('jit').off();require('ffi').log=function() end;require('setupkoenv');require('ffi/posix_h')
local ffi=require('ffi');local json=require('json')
local length=assert(io.stdin:read('*l'));assert(length:match('^[1-9]%d*$') and tonumber(length)<=65536)
local input=json.decode(assert(io.stdin:read(tonumber(length))))
assert(type(input.token)=='string' and input.token:match('^[a-f0-9]+$') and #input.token==32 and type(input.armed)=='boolean')
local function emit(kind,value)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_'..kind..'='..json.encode(value)..'\n');io.stdout:flush()
end
local function rpc(kind,value)
    value=value or {};value.kind=kind;emit('STEP',value)
    local reply=json.decode(assert(io.stdin:read('*l')))
    assert(reply.kind==kind and type(reply.ok)=='boolean');return reply.ok
end
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local shared=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(shared~=ffi.cast('void *',-1))
local guard_failure=ffi.cast('int *',shared)
local worked,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
    local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..assert(arg[1])..'/?.lua;'..package.path
    local Position=require('weread.lib.native_position_protocol')
    assert(Position.id(input.book_id)==input.book_id and input.credentials.vid==input.cookies.wr_vid)
    assert(Position.integer(input.book_version,1,2147483647) and Position.id(input.chapter_uid)==input.chapter_uid)
    if input.mock_endpoint then
        assert(input.mock_endpoint:match('^http://127%.0%.0%.1:%d+$') and input.credentials.vid=='12345678'
            and input.book_id=='42' and input.credentials.accessToken=='synthetic-access'
            and input.cookies.wr_skey=='synthetic-web-access')
    end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.credentials.vid,name=''},cookies=input.cookies,api_key=''}
    local fd=tonumber(ffi.C.memfd_create('weread-direct-time-auth',1));assert(fd>=0)
    local encoded='return '..require('dump')(auth,nil,true);local offset=0
    while offset<#encoded do
        local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',encoded)+offset,#encoded-offset));assert(n>0);offset=offset+n
    end
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
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
        local sync=value:get('sync',{});sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
        local cache=value:get('cache',{});cache.show_annotations=false;cache.auto_prefetch_next_chapter=false;value:set('cache',cache)
        local report=value:get('read_report',{});report.enabled=false;value:set('read_report',report)
        return value
    end
    local credentials={read=function() return input.credentials,1,nil,false end}
    local Native=require('weread.lib.native_read_access');local capture=Native.capture
    Native.capture=function(settings,existing) return capture(settings,existing or credentials) end
    local Client=require('weread.lib.client');local original=Client.request;local allowed_client
    function Client:request(options)
        assert(self==allowed_client,'direct_time/other_client')
        if input.mock_endpoint then
            self.settings.mock_endpoint=input.mock_endpoint
            local values={pcall(original,self,options)};self.settings.mock_endpoint=nil
            assert(values[1]);return unpack(values,2)
        end
        return original(self,options)
    end
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('direct_time/screenshot_disabled',0) end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
    local function pump(predicate)
        local deadline=socket.gettime()+180
        while not predicate() do assert(socket.gettime()<deadline,'direct_time/timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    Reader:showReader(input.path);pump(function() return Reader.instance and Reader.instance.weread end)
    local reader=Reader.instance;local host=reader.weread
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    host.offline_time.update=function() return true end;host.isNetworkConnected=function() return true end
    local account=host.library_db:accountKey();assert(account==require('weread.lib.native_position_contract').account_key(input.credentials.vid))
    local ledger=host.offline_time.store;local coverage=host.readtime_coverage
    local C=require('weread.lib.readtime_transfer_contract');local rows=assert(ledger:pending(account))
    assert(C.digest(rows)==input.ledger_hash and #rows>0)
    local journal=require('weread.lib.readtime_transfer_store'):new{ledger=ledger,coverage=coverage,codec=host.client}
    local selected;allowed_client=host.client
    local guard=require('spec.koreader.native_time_http_guard').install(host.client,{
        grant=input.credentials,book_id=input.book_id,chapter_uid=input.chapter_uid,book_version=input.book_version,
        native_direct=true,cookies=input.cookies,months=input.months,now=os.time,
        current=function() return host._offline_time_review~=nil end,selection=function() return selected end,
        record=function() local record=assert(journal:pending(account));assert(record.phase=='claimed');return record end,
        rpc=function(kind,value) return rpc(kind,value) end})
    local guarded=host.client.request
    host.client.request=function(self,options)
        local result={pcall(guarded,self,options)}
        if not result[1] then
            local codes={['native_time_http/headers']=1,['native_time_http/route']=2,['native_time_http/body']=3,
                ['native_time_http/session']=4,['native_time_http/options']=5,['native_time_http/record']=6,
                ['native_time_http/denied']=7,['native_time_http/receipt']=8}
            local stages={native_chapter_info=1,native_chapter_catalog=2,native_chapter_download=3,
                source_currentness=4,native_time_metadata=5,native_time_progress=6,shelf_progress=7,
                native_shelf=8,native_time_statistics=9,native_time_config=10,native_time_feature=11,native_time_write=12}
            guard_failure[0]=codes[result[2]] or 9;guard_failure[1]=stages[options.diagnostic_api] or 0
            error('direct_time/guard',0)
        end
        return unpack(result,2)
    end
    local service=require('weread.lib.readtime_transfer_service'):new{settings=host.settings,client=host.client,journal=journal,
        credentials=credentials,scheduler=UI,task_options={allow_current_native=true},acquire=function(book)
            return require('weread.lib.readtime_transfer_lease').acquire(host,book,function() return host._offline_time_review~=nil end)
        end}
    local start=service.start;local background=false
    function service:start(mode,owner,selection,refs,check,callback)
        assert(mode=='send' and owner==account and selection.native_direct and selection.current_day
            and selection.book_id==input.book_id and #refs==1 and refs[1].kind=='native_direct')
        selected=selection
        if not rpc('selection',{selection=selection,reference=refs[1]}) then return false,'unavailable' end
        local started,why=start(self,mode,owner,selection,refs,check,callback)
        if started then
            local worker=assert(self.worker and self.worker.job)
            assert(type(worker.pid)=='number' and worker.pid~=tonumber(ffi.C.getpid()));background=true
        end
        return started,why
    end
    host.offline_time_transfer_service=service
    host:showOfflineTimeStatus();pump(function() return host._offline_time_menu~=nil end)
    local tr=require('weread.lib.i18n').tr;local chosen
    for _,item in ipairs(host._offline_time_menu.item_table) do if item.text==tr('Check today’s E-Ink chapter time') then chosen=item end end
    assert(chosen,'direct_time/menu');chosen.callback();pump(function() return host._offline_time_detail~=nil end)
    local send
    for _,row in ipairs(host._offline_time_detail.buttons) do for _,button in ipairs(row) do
        if button.text==tr('Transfer this batch') then assert(not send);send=button end
    end end
    assert(send and type(send.callback)=='function','direct_time/button');send.callback()
    pump(function() return host._offline_time_detail~=nil and service.job==nil end)
    local expected=input.armed and 'This batch is independently confirmed in cloud reading time.'
        or 'Cloud accounting is not confirmed. The request is kept and will not be sent again.'
    assert(host._offline_time_detail.title==tr(expected),'direct_time/dialog')
    local pending=journal:pending(account);local summary=assert(ledger:summary(account));local phase=pending and pending.phase or 'none'
    assert(background and not host._offline_time_transfer_lock and
        (input.armed and phase=='none' and summary.confirmed==selected.seconds
        or not input.armed and phase=='claimed' and summary.confirmed==0),'direct_time/ledger')
    -- Guard state lives in the worker, so the broker's claim/receipt frames
    -- supply the independent send count; do not trust the parent's fork copy.
    assert(guard and selected);host:closeOfflineTimeUI();reader:onClose(false)
    local status=ffi.new('int[1]')
    pump(function()
        local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
        while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end
        return child==-1
    end)
    emit('RESULT',{result='PASS',native_menu=true,background_service=true,local_phase=phase,workers_reaped=true})
end)
if not worked then
    local module,line
    if type(reason)=='string' then module,line=reason:match('([%w_%-]+%.lua):(%d+):') end
    emit('RESULT',{result='UNVERIFIED',failed_module=module or 'unknown',failed_line=tonumber(line) or 0,
        guard_failure=tonumber(guard_failure[0]),guard_stage=tonumber(guard_failure[1])})
    os.exit(1)
end
