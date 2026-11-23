-- Actual packaged KOReader plugin, synthetic scoped transport, no account I/O.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json')
local report={result='UNVERIFIED',phase='init',checks=0,requests=0,posts=0,screenshots=0}
local function expect(value)
    report.checks=report.checks+1
    if not value then error('reading_state_ui_probe:'..debug.getinfo(2,'l').currentline,0) end
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
        assert(require('weread.lib.native_credentials'):new(value):save({vid='900000',accessToken='synthetic-reading-access',
            refreshToken='synthetic-reading-refresh',deviceId=string.rep('1',32)},value:get_auth_scope(),0,2))
        return value
    end
    local mode='zero';local parent=tonumber(ffi.C.getpid())
    local calls=home..'/requests.txt';local Client=require('weread.lib.client')
    function Client:request(options)
        local headers=options.headers or {}
        local id=options.url:match('^https://i%.weread%.qq%.com/book/getProgress%?bookId=(.+)$')
        assert((id=='41' or id=='CB_abc') and options.method=='GET' and not options.body
            and options.skip_cookie and options.persist_response_cookies==false and options.sensitive
            and headers.vid=='900000' and headers.accessToken=='synthetic-reading-access'
            and not headers.Cookie and not headers.Authorization and tonumber(ffi.C.getpid())~=parent)
        local file=assert(io.open(calls,'a'));file:write('GET\n');file:close()
        require('socket').sleep(mode=='slow' and 2 or .35)
        if mode=='unauthorized' then return '',401 end
        if mode=='missing' then return json.encode({book={bookId=id}}),200 end
        if mode=='foreign' then return json.encode({book={bookId='CB_foreign',isStartReading=1}}),200 end
        return json.encode({book={bookId=id,isStartReading=mode=='one' and 1 or 0,chapterUid=8,progress=35}}),200
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    expect(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);local plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function() return true end
    local notices={};local old_info=plugin.showInfo
    function plugin:showInfo(text) notices[#notices+1]=text;return old_info(self,text) end
    local tr=require('weread.lib.plugin_util').tr
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(test)
        local deadline=socket.gettime()+40
        while not test() do assert(socket.gettime()<deadline);tick() end
    end
    local function row(menu)
        for _,item in ipairs(menu.item_table) do if item.text==tr('Check started-reading status') then return item end end
        error('missing started-reading action')
    end
    local function close_notice()
        local top=UI:getTopmostVisibleWidget()
        if top and top~=plugin._shelf_state_menu and top~=plugin.ui then UI:close(top) end
    end
    local function read(id,selected_mode,expected)
        mode=selected_mode;notices={}
        assert(plugin:showShelfState(id));local menu=assert(plugin._shelf_state_menu)
        menu:onMenuSelect(row(menu))
        expect(plugin._reading_state_ui~=nil)
        local beat=false;UI:scheduleIn(.1,function() beat=true end);wait(function() return beat end)
        expect(plugin._reading_state_ui~=nil)
        wait(function() return plugin._reading_state_ui==nil end)
        expect(#notices==1 and notices[1]==tr(expected))
        expect(plugin._shelf_state_menu==menu)
        UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_READING_SHOTS'))..'/'..selected_mode..'.png')
        report.screenshots=report.screenshots+1
        close_notice();require('weread.ui.shelf_state').cancel(plugin)
    end
    report.phase='states'
    read('41','zero','WeRead has not marked this book as started. Its saved position and finished status may be different.')
    read('CB_abc','one','WeRead records this book as started.')
    read('41','missing','WeRead did not provide a started-reading status for this book.')
    read('41','foreign','Could not check started-reading status.')
    read('41','unauthorized','Authorize or renew E-Ink login in settings, then try again.')
    report.phase='cancel';mode='slow';notices={}
    assert(plugin:showShelfState('41'));local menu=assert(plugin._shelf_state_menu)
    menu:onMenuSelect(row(menu));expect(plugin._reading_state_ui~=nil)
    require('weread.ui.shelf_state').cancel(plugin)
    expect(not plugin._reading_state_ui and not plugin.busy_message and not plugin._shelf_state_menu)
    for _i=1,30 do tick() end
    expect(#notices==0)
    local f=io.open(calls,'r');local contents=f and f:read('*a') or '';if f then f:close() end
    for line in contents:gmatch('[^\n]+') do expect(line=='GET');report.requests=report.requests+1 end
    expect(report.requests>=5 and report.requests<=6)
    report.result='PASS';report.phase='complete'
end)
if not ok then report.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,150) end
print('\nWEREAD_READING_STATE_RESULT='..json.encode(report))
os.exit(ok and 0 or 1)
