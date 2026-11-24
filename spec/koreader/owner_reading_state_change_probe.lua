-- One packaged native UI operation, bound to an independent preflight snapshot.
-- The caller owns the durable one-shot intent and performs independent readback.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local report={result='UNVERIFIED',phase='input',gets=0,posts=0,denied=0,files=0}
local profile,plugin,counters,memory
local ok,reason=pcall(function()
    local input
    do local raw=io.stdin:read(2*1024*1024+1);assert(#raw<=2*1024*1024);input=json.decode(raw) end
    local grant,id=input.credentials,input.book_id
    local desired,armed=input.desired,input.armed
    assert(type(grant)=='table' and type(desired)=='boolean' and type(armed)=='boolean'
        and armed==(os.getenv('WEREAD_STARTED_CHANGE_ARMED')=='1'))
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-started%-owner%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('owner_started/screenshots_disabled',0) end
    local Contract=require('weread.lib.reading_state_change_contract')
    assert(Contract.id(id) and type(grant.vid)=='string')
    local expected=Contract.make(input.shelf,input.progress,id,grant.vid,desired).metadata
    assert(expected.before~=desired)
    local path=debug.getinfo(1,'S').source:match('^@(.*/)')
    profile=dofile(path..'native_account_profile.lua');profile.start(home,grant,#input.shelf.books)
    if input.mock_port~=nil then
        assert(type(input.mock_port)=='number' and input.mock_port%1==0 and input.mock_port>=1 and input.mock_port<=65535
            and os.getenv('WEREAD_STARTED_CHANGE_MOCK')==tostring(input.mock_port) and id=='41' and grant.vid=='900000'
            and grant.accessToken=='synthetic-native-access' and grant.refreshToken=='synthetic-native-refresh'
            and grant.deviceId=='eink334691225'..string.rep('1',19))
        local Settings=require('weread.lib.settings');local new=Settings.new
        function Settings:new() local value=new(self);value.mock_endpoint='http://127.0.0.1:'..input.mock_port;return value end
    else assert(not os.getenv('WEREAD_STARTED_CHANGE_MOCK')) end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,128,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local Client=require('weread.lib.client');local request=Client.request
    local Hash=require('weread.lib.thought_edit_contract')
    function Client:request(options)
        local headers=options.headers or {}
        local safe=options.sensitive and options.skip_cookie and options.persist_response_cookies==false
            and headers.vid==grant.vid and headers.accessToken==grant.accessToken
            and not headers.Cookie and not headers.Authorization and tonumber(ffi.C.getpid())~=parent
        local get=options.method=='GET' and not options.body and
            (options.url==base..'/shelf/sync' or options.url==base..'/book/getProgress?bookId='..id)
        local post=options.method=='POST' and options.url==base..'/book/markstatus' and type(options.body)=='string'
        if post then
            local decoded,body=pcall(json.decode,options.body)
            post=decoded and type(body)=='table' and Hash.body_hash(body)==expected.request_hash
            local journal=plugin and plugin._reading_state_change_service and plugin._reading_state_change_service.journal
            local record=journal and journal:read()
            post=post and record and record.phase=='pending' and Contract.same(record.metadata,expected)
        end
        if not safe or not (get or post) or get and counters[0]>=20 or post and (not armed or counters[1]~=0) then
            counters[2]=counters[2]+1;error('owner_started/transport_scope',0)
        end
        if get then counters[0]=counters[0]+1 else counters[1]=counters[1]+1 end
        return request(self,options)
    end
    plugin=dofile(source..'/main.lua'):new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkConnected=function() return true end;plugin.isNetworkOnline=function() return true end
    local notices={};local show=plugin.showInfo
    function plugin:showInfo(text) notices[#notices+1]=text;return show(self,text) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local socket=require('socket');local tr=require('weread.lib.plugin_util').tr
    local workers={}
    local function wait(test)
        local deadline=socket.gettime()+60
        while not test() do
            assert(socket.gettime()<deadline)
            local worker=plugin._reading_state_change_service and plugin._reading_state_change_service.worker
            if worker and worker.job then workers[worker.job.pid]=true end
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    report.phase='menu';assert(plugin:showShelfState(id));local menu=assert(plugin._shelf_state_menu)
    local action
    for _,item in ipairs(menu.item_table) do if item.text==tr('Change started-reading status') then action=item end end
    assert(action);menu:onMenuSelect(action)
    local heartbeat=false;UI:scheduleIn(.1,function() heartbeat=true end)
    wait(function() return heartbeat and plugin._reading_state_change_ui and plugin._reading_state_change_ui.dialog end)
    local service=assert(plugin._reading_state_change_service);assert(Contract.same(service.preview.metadata,expected))
    local dialog=plugin._reading_state_change_ui.dialog
    assert(dialog.ok_text==tr(desired and 'Mark as started' or 'Mark as not started'))
    report.phase='preview';report.preview_verified=true
    if armed then
        report.phase='commit';heartbeat=false;UI:scheduleIn(.1,function() heartbeat=true end);dialog.ok_callback()
        wait(function() return heartbeat and not plugin._reading_state_change_ui end)
        assert(#notices==1 and notices[1]==tr('The current started-reading status was verified in WeRead.'))
        assert(not service:pending() and counters[1]==1)
    else
        dialog.cancel_callback();dialog.ok_callback();assert(not plugin._reading_state_change_ui and counters[1]==0)
    end
    assert(counters[2]==0 and counters[0]>=2)
    report.phase='audit';plugin:closeWeReadUI()
    for pid in pairs(workers) do wait(function() return require('ffi/util').isSubProcessDone(pid) end) end
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for name in lfs.dir(dir) do if name~='.' and name~='..' and not (dir==home and name=='plugins') then
            local file=dir..'/'..name;local info=assert(lfs.symlinkattributes(file))
            if info.mode=='directory' then audit(file)
            elseif info.mode=='file' then
                report.files=report.files+1;assert(report.files<=1024 and info.size<=16*1024*1024)
                local f=assert(io.open(file,'rb'));local bytes=f:read('*a');f:close()
                for _,secret in ipairs({grant.vid,grant.accessToken,grant.refreshToken,grant.deviceId}) do
                    if type(secret)=='string' and #secret>=6 then assert(not bytes:find(secret,1,true)) end
                end
            else error('owner_started/profile_entry',0) end
        end end
    end
    audit(home);assert(report.files>0);report.credential_audit=true
    report.phase,report.result='complete','PASS'
end)
if counters then report.gets,report.posts,report.denied=tonumber(counters[0]),tonumber(counters[1]),tonumber(counters[2]) end
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if profile then pcall(profile.close) end
if memory then ffi.C.munmap(memory,128) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_reading_state_change_probe%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_OWNER_STARTED_CHANGE='..json.encode(report)..'\n');io.stdout:flush()
os.exit(ok and 0 or 1)
