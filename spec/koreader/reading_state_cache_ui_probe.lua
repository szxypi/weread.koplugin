-- Packaged native UI, synthetic credentials and transport; profile survives both phases.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json')
local phase=assert(os.getenv('WEREAD_CACHE_PHASE'))
local report={result='UNVERIFIED',phase=phase,checks=0,requests=0}
local function expect(value)
    report.checks=report.checks+1
    if not value then error('cache_ui:'..debug.getinfo(2,'l').currentline,0) end
end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local Settings=require('weread.lib.settings');local settings_new=Settings.new
    function Settings:new()
        local value=settings_new(self)
        value.store:saveSetting('auth_schema_version',1);value.store:saveSetting('auth_epoch',1)
        value.store:saveSetting('account',{user_vid='900000',name='合成用户'});value:flush()
        if phase=='online' then
            assert(require('weread.lib.native_credentials'):new(value):save({vid='900000',accessToken='synthetic-access',
                refreshToken='synthetic-refresh',deviceId=string.rep('1',32)},value:get_auth_scope(),0,2))
        end
        return value
    end
    local parent=tonumber(ffi.C.getpid());local calls=home..'/requests.txt'
    local Client=require('weread.lib.client')
    function Client:request(options)
        local id=options.url:match('^https://i%.weread%.qq%.com/book/getProgress%?bookId=(.+)$')
        local h=options.headers or {}
        assert(phase=='online' and (id=='41' or id=='CB_abc' or id=='55') and options.method=='GET'
            and not options.body and options.skip_cookie and options.persist_response_cookies==false
            and options.sensitive and h.vid=='900000' and h.accessToken=='synthetic-access'
            and not h.Cookie and not h.Authorization and tonumber(ffi.C.getpid())~=parent)
        local file=assert(io.open(calls,'a'));file:write('GET\n');file:close()
        if id=='55' then return json.encode({book={bookId=id}}),200 end
        return json.encode({book={bookId=id,isStartReading=id=='41' and 0 or 1}}),200
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    expect(#Loader.enabled_plugins==1)
    local plugin=dofile(source..'/main.lua'):new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkOnline=function() return phase=='online' end
    local notices={};local old_info=plugin.showInfo
    function plugin:showInfo(text) notices[#notices+1]=text;return old_info(self,text) end
    local offline=0;plugin.showOffline=function() offline=offline+1 end
    local util=require('weread.lib.plugin_util');local tr=util.tr
    local cache=require('weread.lib.reading_state_cache'):new(plugin.library_db,plugin.library_db:accountKey())
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(test)
        local deadline=socket.gettime()+40
        while not test() do assert(socket.gettime()<deadline);tick() end
    end
    local function select_book(id)
        notices={};assert(plugin:showShelfState(id));local menu=assert(plugin._shelf_state_menu)
        local action
        for _,item in ipairs(menu.item_table) do if item.text==tr('Check started-reading status') then action=item end end
        assert(action);menu:onMenuSelect(action)
        if phase=='online' then wait(function() return not plugin._reading_state_ui end) end
    end
    local function close()
        local top=UI:getTopmostVisibleWidget()
        if top and top~=plugin._shelf_state_menu and top~=plugin.ui then UI:close(top) end
        require('weread.ui.shelf_state').cancel(plugin)
    end
    if phase=='online' then expect(cache:write('55',true,nil)) end
    for _,item in ipairs({{'41',false},{'CB_abc',true},{'55','missing'}}) do
        select_book(item[1]);local saved=assert(cache:read(item[1]));expect(saved.started==item[2])
        if phase=='offline' then
            local text=item[2]=='missing' and 'Saved on %1: WeRead did not provide a started-reading status. This saved status may be out of date.'
                or item[2] and 'Saved on %1: this book was marked as started. This saved status may be out of date.'
                or 'Saved on %1: this book was not marked as started. This saved status may be out of date.'
            expect(#notices==1 and notices[1]==util.T(tr(text),os.date('%Y-%m-%d %H:%M',saved.checked_at)))
        else expect(#notices==1) end
        close()
    end
    if phase=='offline' then select_book('77');expect(offline==1 and #notices==0);close() end
    local file=assert(io.open(calls,'r'));local contents=file:read('*a');file:close()
    for line in contents:gmatch('[^\n]+') do expect(line=='GET');report.requests=report.requests+1 end
    expect(report.requests==3)
    report.result='PASS'
end)
if not ok then report.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,150) end
print('\nWEREAD_CACHE_UI_RESULT='..json.encode(report))
os.exit(ok and 0 or 1)
