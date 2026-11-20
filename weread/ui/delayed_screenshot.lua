-- Delay a native KOReader screenshot so the user can navigate first.
-- The timer belongs to the application, not to the page where it was armed.
local ButtonDialog=require('ui/widget/buttondialog')
local UI=require('ui/uimanager')
local util=require('weread.lib.plugin_util')
local _=util.tr
local M={}
local pending,chooser

local function info(host,text,transient)
    if not host then return end
    if transient and type(host.showTransientInfo)=='function' then host:showTransientInfo(text,2)
    elseif type(host.showInfo)=='function' then host:showInfo(text) end
end
local function active_screenshoter()
    -- ReaderUI and FileManager own KOReader's native screenshot controller.
    -- Resolve them at capture time: the user may have changed pages/books.
    for _,name in ipairs({'apps/reader/readerui','apps/filemanager/filemanager'}) do
        local app=package.loaded[name]
        local ui=type(app)=='table' and app.instance
        local screenshot=ui and ui.screenshot
        if screenshot and type(screenshot.onScreenshot)=='function' then return screenshot end
    end
end
function M.cancel()
    local old=pending;pending=nil
    if old then UI:unschedule(old.fire) end
    if chooser then local dialog=chooser;chooser=nil;UI:close(dialog) end
    return old~=nil
end
function M.is_armed() return pending~=nil end
function M.arm(host,seconds)
    if seconds~=5 and seconds~=10 and seconds~=15 then return false end
    M.cancel()
    local state={}
    state.fire=function()
        if pending~=state then return end
        pending=nil
        local screenshot=active_screenshoter()
        if not screenshot then info(host,_('Screenshot is unavailable on this device.'));return end
        local ok,result=pcall(screenshot.onScreenshot,screenshot)
        if not ok or result==false then info(host,_('Could not take the screenshot.')) end
    end
    pending=state
    UI:scheduleIn(seconds,state.fire)
    info(host,util.T(_('Screenshot in %1 seconds.'),seconds),true)
    return true
end
function M.show(host)
    if chooser then local dialog=chooser;chooser=nil;UI:close(dialog) end
    local dialog
    local rows={}
    for _index,seconds in ipairs({5,10,15}) do
        rows[#rows+1]={{id='screenshot_delay_'..seconds,text=util.T(_('%1 seconds'),seconds),callback=function()
            if chooser~=dialog then return end
            chooser=nil;UI:close(dialog);M.arm(host,seconds)
        end}}
    end
    if pending then
        rows[#rows+1]={{id='cancel_screenshot',text=_('Cancel pending screenshot'),callback=function()
            if chooser~=dialog then return end
            M.cancel();info(host,_('Screenshot canceled.'),true)
        end}}
    end
    rows[#rows+1]={{text=_('Close'),callback=function() if chooser==dialog then chooser=nil end;UI:close(dialog) end}}
    dialog=ButtonDialog:new{title=_('Delayed screenshot'),buttons=rows}
    local close=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if chooser==instance then chooser=nil end
        if close then return close(instance,...) end
    end
    chooser=dialog;UI:show(dialog)
    return dialog
end
return M
