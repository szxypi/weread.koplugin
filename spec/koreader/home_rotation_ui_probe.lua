-- Packaged plugin, actual KOReader file manager and synthetic offline bookshelf.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local report={result='UNVERIFIED',phase='init',checks=0}
local function expect(value)
    report.checks=report.checks+1
    if not value then error('home_rotation:'..debug.getinfo(2,'l').currentline,0) end
end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local Settings=require('weread.lib.settings');local make=Settings.new
    function Settings:new()
        local value=make(self);value.store:saveSetting('auth_schema_version',1);value.store:saveSetting('auth_epoch',1)
        value.store:saveSetting('account',{user_vid='900000',name='合成用户'});value:flush();return value
    end
    local Client=require('weread.lib.client');function Client:request() error('unexpected network',0) end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    expect(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);local plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function() return false end
    plugin.fetchVisibleShelfCovers=function() end;plugin.refreshVisibleShelfProgress=function() end
    local preferences=plugin:homePreferences();preferences.recent_limit=24;plugin.settings:set('home',preferences);plugin.settings:flush()
    local books={};for index=1,24 do books[index]={bookId=tostring(1000+index),title='合成书籍'..index,
        author='测试作者',readUpdateTime=1800000000-index} end
    expect(plugin.library_db:cacheShelf(books,{}))
    local UI=require('ui/uimanager');local Screen=Device.screen;local tr=require('weread.lib.plugin_util').tr
    local socket=require('socket');local Event=require('ui/event')
    local function item(menu,label)
        for _,entry in ipairs(menu.item_table) do if entry.text==tr(label) then return entry end end
        error('home_rotation/missing_'..label)
    end
    local function rotate(label,mode)
        local previous=assert(plugin.shelf_view);local anchor=(previous.page-1)*previous.page_size+1
        plugin:showHomeQuickSettings();local menu=assert(plugin._home_controls_menu)
        menu:onMenuSelect(item(menu,'Screen orientation'))
        if label=='Landscape left' then
            expect(item(menu,'Portrait').mandatory_func()=='✓' and item(menu,'Landscape left').mandatory_func()=='')
            UI:forceRePaint();Screen:shot(assert(os.getenv('WEREAD_ROTATION_SHOTS'))..'/orientation-menu.png')
        end
        menu:onMenuSelect(item(menu,label))
        expect(Screen:getRotationMode()==mode and plugin.shelf_view~=previous and previous._shelf_closed)
        local view=assert(plugin.shelf_view);expect(view.screen_w==Screen:getWidth() and view.screen_h==Screen:getHeight())
        expect((view.page-1)*view.page_size+1<=anchor and view.page*view.page_size>=anchor)
        expect(not plugin._home_controls_menu and view._discovery_tab=='home')
        UI:forceRePaint()
    end
    plugin:showHome();local view=assert(plugin.shelf_view)
    expect(#view.books==24 and view.page_count>1 and Screen:getRotationMode()==Screen.DEVICE_ROTATED_UPRIGHT)
    view.on_page_changed(2);view=assert(plugin.shelf_view);expect(view.page==2)
    local width,height=Screen:getWidth(),Screen:getHeight()
    report.phase='left';rotate('Landscape left',Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE)
    expect(Screen:getWidth()==height and Screen:getHeight()==width)
    Screen:shot(assert(os.getenv('WEREAD_ROTATION_SHOTS'))..'/home-landscape.png')
    report.phase='right';rotate('Landscape right',Screen.DEVICE_ROTATED_CLOCKWISE)
    report.phase='upside_down';rotate('Portrait upside down',Screen.DEVICE_ROTATED_UPSIDE_DOWN)
    report.phase='upright';rotate('Portrait',Screen.DEVICE_ROTATED_UPRIGHT)
    expect(Screen:getWidth()==width and Screen:getHeight()==height)
    local old=plugin.shelf_view;plugin:showHomeQuickSettings();local menu=assert(plugin._home_controls_menu)
    menu:onMenuSelect(item(menu,'Screen orientation'));menu:onMenuSelect(item(menu,'Portrait'))
    expect(plugin.shelf_view==old and Screen:getRotationMode()==Screen.DEVICE_ROTATED_UPRIGHT)
    local function external(mode)
        local before=assert(plugin.shelf_view);local anchor=(before.page-1)*before.page_size+1
        expect(UI:getTopmostVisibleWidget()==before)
        UI:broadcastEvent(Event:new('SetRotationMode',mode))
        local deadline=socket.gettime()+5
        while plugin.shelf_view==before do
            assert(socket.gettime()<deadline,'external rotation did not reflow')
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
        local after=assert(plugin.shelf_view)
        expect(before._shelf_closed and after.screen_w==Screen:getWidth() and after.screen_h==Screen:getHeight())
        expect((after.page-1)*after.page_size+1<=anchor and after.page*after.page_size>=anchor)
        UI:forceRePaint();return after
    end
    report.phase='external_home';external(Screen.DEVICE_ROTATED_CLOCKWISE)
    plugin:showBookshelf();view=assert(plugin.shelf_view);expect(#view.books==24 and view.page_count>1)
    view.on_page_changed(2);view=assert(plugin.shelf_view);expect(view.page==2)
    report.phase='external_shelf';view=external(Screen.DEVICE_ROTATED_UPSIDE_DOWN);expect(#view.books==24)
    local shelf=plugin.settings:get('shelf');shelf.view_mode='list';shelf.paginated=false
    plugin.settings:set('shelf',shelf);plugin.settings:flush();plugin:showBookshelf()
    view=assert(plugin.shelf_view);expect(not view.paged)
    view.scroll:setScrolledOffset{x=0,y=50};expect(view:getScrollOffset().y==50)
    report.phase='external_scrolling_shelf';view=external(Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE)
    expect(not view.paged and view:getScrollOffset().y==50)
    plugin.discovery_state={account=plugin.library_db:accountKey(),books=books,kind='search',keyword='合成',
        loaded_at=os.time(),history={},has_more=false}
    plugin:showBookstore();view=assert(plugin.shelf_view);expect(view._discovery_tab=='store' and #view.books==24)
    report.phase='external_store';view=external(Screen.DEVICE_ROTATED_UPRIGHT)
    expect(view._discovery_tab=='store' and plugin.discovery_state.keyword=='合成')
    Screen:shot(assert(os.getenv('WEREAD_ROTATION_SHOTS'))..'/store-portrait.png')
    plugin:showHome();view=assert(plugin.shelf_view);plugin:showHomeQuickSettings()
    menu=assert(plugin._home_controls_menu);expect(UI:getTopmostVisibleWidget()==menu)
    report.phase='popup';UI:broadcastEvent(Event:new('SetRotationMode',Screen.DEVICE_ROTATED_CLOCKWISE))
    for _index=1,5 do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    expect(plugin.shelf_view==view and not view._shelf_closed)
    menu:onCloseAllMenus()
    local deadline=socket.gettime()+5
    while plugin.shelf_view==view do
        assert(socket.gettime()<deadline,'rotation after popup close did not reflow')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
    expect(plugin.shelf_view.screen_w==Screen:getWidth() and not plugin._home_controls_menu)
    report.phase='rapid';view=assert(plugin.shelf_view)
    UI:broadcastEvent(Event:new('SetRotationMode',Screen.DEVICE_ROTATED_UPSIDE_DOWN))
    UI:broadcastEvent(Event:new('SetRotationMode',Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE))
    deadline=socket.gettime()+5
    while plugin.shelf_view==view do
        assert(socket.gettime()<deadline,'rapid rotations did not reflow')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
    expect(Screen:getRotationMode()==Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
        and plugin.shelf_view.screen_w==Screen:getWidth() and plugin.shelf_view.screen_h==Screen:getHeight())
    report.phase='close';UI:broadcastEvent(Event:new('SetRotationMode',Screen.DEVICE_ROTATED_UPRIGHT))
    plugin:closeWeReadUI()
    for _index=1,5 do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    expect(plugin.shelf_view==nil)
    report.result='PASS';report.phase='complete'
end)
if not ok then report.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,160) end
print('\nWEREAD_HOME_ROTATION_RESULT='..json.encode(report))
os.exit(ok and 0 or 1)
