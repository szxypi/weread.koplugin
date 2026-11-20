-- Actual KOReader screenshot controller, synthetic pages and an isolated folder.
local M={}
local UI=require('ui/uimanager')
local socket=require('socket')
local time=require('ui/time')
local lfs=require('libs/libkoreader-lfs')
local tr=require('weread.lib.plugin_util').tr
local Screenshot=require('weread.ui.delayed_screenshot')
local old_folder
local directory
local function count_png()
    local count=0
    for name in lfs.dir(directory) do
        if name:match('%.png$') then
            local file=assert(io.open(directory..'/'..name,'rb'))
            assert(file:read(8)=='\137PNG\r\n\26\n');file:close();count=count+1
        end
    end
    return count
end
local function select_delay(seconds)
    local chooser,button
    local deadline=socket.gettime()+5
    while not button do
        assert(socket.gettime()<deadline,'screenshot chooser did not become visible')
        UI:shiftScheduledTasksBy(-time.ms(500));UI:setInputTimeout(0);UI:handleInput()
        chooser=UI:getTopmostVisibleWidget()
        if chooser and type(chooser.getButtonById)=='function' then
            button=chooser:getButtonById('screenshot_delay_'..seconds)
        end
        if not button then socket.sleep(.01) end
    end
    UI:forceRePaint();button:onTapSelectButton()
    assert(Screenshot.is_armed())
end
local function native_capture(ui)
    local native=assert(ui.screenshot);local previous=native.onScreenshot;local seen={count=0}
    native.onScreenshot=function(self,...)
        seen.count=seen.count+1
        seen.page=self.ui.document and self.ui:getCurrentPage() or nil
        return previous(self,...)
    end
    return seen,function() native.onScreenshot=previous end
end
function M.home(plugin,fm,evidence)
    directory=evidence..'/delayed-native'
    assert(lfs.mkdir(directory));old_folder=G_reader_settings:readSetting('screenshot_dir')
    G_reader_settings:saveSetting('screenshot_dir',directory)
    local seen,restore=native_capture(fm)
    plugin:showHomeQuickSettings()
    local menu=assert(plugin._home_controls_menu);local entry
    for _,item in ipairs(menu.item_table) do if item.text==tr('Delayed screenshot') then entry=item end end
    assert(entry,'home screenshot entry missing');menu:onMenuSelect(entry)
    select_delay(5)
    plugin:showBookshelf()
    local deadline=socket.gettime()+8
    while Screenshot.is_armed() do
        assert(socket.gettime()<deadline,'native screenshot timer did not fire')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.02)
    end
    assert(seen.count==1 and count_png()==1,'home screenshot was not saved by KOReader')
    UI:close(assert(UI:getTopmostVisibleWidget()))
    restore();plugin:showHome()
end
function M.reader(plugin,reader)
    local seen,restore=native_capture(reader)
    assert(plugin:onShowWeReadQuickMenu())
    local quick=assert(UI:getTopmostVisibleWidget())
    UI:forceRePaint()
    assert(quick:getButtonById('delayed_screenshot')):onTapSelectButton()
    UI:shiftScheduledTasksBy(-time.s(1));UI:setInputTimeout(0);UI:handleInput()
    select_delay(5)
    local destination=math.min(2,reader.document:getPageCount())
    reader.rolling:onGotoPage(destination)
    UI:forceRePaint()
    local deadline=socket.gettime()+8
    while Screenshot.is_armed() do
        assert(socket.gettime()<deadline,'reader screenshot timer did not fire')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
    assert(seen.count==1 and seen.page==reader:getCurrentPage(),
        ('native reader screenshot state armed=%s count=%s captured=%s current=%s'):format(
            tostring(Screenshot.is_armed()),tostring(seen.count),tostring(seen.page),tostring(reader:getCurrentPage())))
    assert(count_png()==2,'reader screenshot was not saved by KOReader')
    UI:close(assert(UI:getTopmostVisibleWidget()))
    local expected=1
    if os.getenv('WEREAD_TEST_DELAYED_SCREENSHOT_LONG')=='1' then
        for _index,seconds in ipairs({10,15}) do
            Screenshot.show(plugin);local start=socket.gettime();select_delay(seconds)
            local limit=start+seconds+6
            while Screenshot.is_armed() do
                assert(socket.gettime()<limit,'long screenshot timer did not fire')
                UI:setInputTimeout(0);UI:handleInput();socket.sleep(.02)
            end
            assert(socket.gettime()-start>=seconds-.25,'long screenshot timer fired too early')
            expected=expected+1
            assert(seen.count==expected and seen.page==reader:getCurrentPage() and count_png()==expected+1)
            UI:close(assert(UI:getTopmostVisibleWidget()))
        end
    end
    Screenshot.arm(plugin,5);plugin:onSuspend();assert(not Screenshot.is_armed(),'suspend left screenshot armed')
    plugin:onResume();UI:shiftScheduledTasksBy(-time.s(8));UI:handleInput()
    assert(seen.count==expected and count_png()==expected+1,'suspended screenshot still fired')
    restore()
    if old_folder==nil then G_reader_settings:delSetting('screenshot_dir')
    else G_reader_settings:saveSetting('screenshot_dir',old_folder) end
end
return M
