-- Reader display controls that use KOReader's native footer and device APIs.
local ButtonDialog=require('ui/widget/buttondialog')
local Device=require('device')
local UI=require('ui/uimanager')
local Context=require('weread.lib.reader_progress_context')
local Actions=require('weread.lib.reader_footer_actions')
local util=require('weread.lib.plugin_util')
local _=util.tr
local M={}
local last_modes=setmetatable({},{__mode='k'})
local names={all_at_once='Show selected together',progress_bar='Progress bar',page_progress='Current page',
    percentage='Reading percentage',chapter_time_to_read='Chapter time remaining',time='Current time',battery='Battery'}

local function has_frontlight()
    return Device:hasFrontlight() and type(Device.showLightDialog)=='function'
end

local function has_eink_screen()
    return Device:hasEinkScreen()
end

local function same_global_settings(footer)
    if type(G_reader_settings)~='table' or type(G_reader_settings.readSetting)~='function' then return false end
    local ok,value=pcall(G_reader_settings.readSetting,G_reader_settings,'footer')
    return ok and value==footer.settings
end
local function can_toggle(footer,view)
    return type(view.footer_visible)=='boolean' and not view.flipping_visible and type(footer.mode)=='number'
        and type(footer.mode_list)=='table' and type(footer.mode_list.off)=='number'
        and type(footer.mode_list.page_progress)=='number' and type(footer.mode_index)=='table'
        and type(footer.applyFooterMode)=='function' and type(footer.onUpdateFooter)=='function'
        and type(footer.rescheduleFooterAutoRefreshIfNeeded)=='function'
        and type(G_reader_settings)=='table' and type(G_reader_settings.saveSetting)=='function'
        and (view.footer_visible and footer.mode~=footer.mode_list.off or not view.footer_visible and footer.mode==footer.mode_list.off)
end
local function enabled_mode(footer,mode)
    if type(mode)~='number' or mode==footer.mode_list.off then return false end
    local name=footer.mode_index[mode]
    if type(name)~='string' then return false end
    if footer.settings.all_at_once then return true end
    return name~='dynamic_filler' and footer.settings[name]==true
        or footer.has_no_mode==true and footer.settings.disable_progress_bar~=true and mode==footer.mode_list.page_progress
end
local function first_mode(footer)
    if footer.settings.all_at_once and (not footer.has_no_mode or footer.settings.disable_progress_bar~=true) then
        return footer.mode_list.page_progress
    end
    local previous=last_modes[footer]
    if enabled_mode(footer,previous) then return previous end
    for index,name in ipairs(footer.mode_index) do
        if name~='dynamic_filler' and footer.settings[name]==true then return index end
    end
    if footer.settings.disable_progress_bar~=true then return footer.mode_list.page_progress end
end
local function toggle_visibility(footer,view)
    if not can_toggle(footer,view) or not same_global_settings(footer) then return false end
    local was_visible=view.footer_visible
    local target
    if was_visible then
        last_modes[footer]=footer.mode;target=footer.mode_list.off
    else
        target=first_mode(footer)
        if not target then return nil end
    end
    local ok=pcall(function()
        footer:applyFooterMode(target)
        assert(view.footer_visible~=was_visible and footer.mode==target)
        G_reader_settings:saveSetting('reader_footer_mode',footer.mode)
        assert(G_reader_settings:readSetting('reader_footer_mode')==footer.mode)
        footer:onUpdateFooter(true)
        footer:rescheduleFooterAutoRefreshIfNeeded()
    end)
    return ok and view.footer_visible~=was_visible
end

function M.cancel(host)
    local state=host and host._weread_reader_display
    if not state then return end
    host._weread_reader_display=nil
    if state.refresh_task then UI:unschedule(state.refresh_task);state.refresh_task=nil end
    if state.dialog then local dialog=state.dialog;state.dialog=nil;UI:close(dialog) end
end

function M.show(host,options)
    options=options or {}
    if host and host._weread_suspended then return false end
    local snapshot=Context.capture(host)
    local ui=snapshot and snapshot.ui;local document=snapshot and snapshot.document
    local view=ui and ui.view;local footer=view and view.footer
    local status_message
    if type(footer)~='table' or type(footer.settings)~='table' or not same_global_settings(footer) then
        status_message=_('Status bar is unavailable for this file.')
    elseif footer.settings.disabled==true then
        status_message=_('Status bar is disabled in KOReader. Enable it there and reopen the book.')
    end
    local frontlight, eink_screen = has_frontlight(), has_eink_screen()
    if not snapshot or status_message and not (frontlight or eink_screen) then
        if host and type(host.showInfo)=='function' then host:showInfo(status_message) end
        return false
    end
    if options.is_current then local ok,valid=pcall(options.is_current);if not ok or valid~=true then return false end end
    M.cancel(host)
    local state={snapshot=snapshot,footer=footer};host._weread_reader_display=state
    local function close()
        if host._weread_reader_display==state then M.cancel(host) end
    end
    local function current()
        if host._weread_reader_display~=state or host._weread_suspended or host.ui~=ui or ui.document~=document
            or document.file~=snapshot.file or ui.view~=view or host._reader_session_gen~=snapshot.session then return false end
        if options.is_current then local ok,valid=pcall(options.is_current);if not ok or valid~=true then return false end end
        return true
    end
    local function footer_current()
        return current() and view.footer==footer and type(footer.settings)=='table' and footer.settings.disabled~=true
    end
    local buttons={};local by_id={}
    local function item(id,label,action)
        local row={id='display_'..id,text=label,enabled=false,callback=action}
        by_id[id]=row;return row
    end
    local function title()
        if status_message then return status_message end
        local mode=footer.settings.all_at_once and _('Selected items shown together') or _('Items cycle one at a time')
        return util.T(_('Status bar · global settings\n%1\nProgress refers to the current file.'),mode)
    end
    local function refresh()
        if not footer_current() then close();return end
        local actions=Actions.inspect(footer)
        local global=same_global_settings(footer)
        local function decorate(id,label,value,available)
            local status=available and (value and _('On') or _('Off')) or _('Unavailable')
            local row=by_id[id]
            row.text=util.T(_('%1: %2'),_(label),status)
            row.enabled=available and global
        end
        decorate('visible','Status bar',view.footer_visible,can_toggle(footer,view))
        for id,label in pairs(names) do
            local action=actions[id]
            decorate(id,label,action and action.checked,action~=nil)
        end
        if state.dialog then pcall(state.dialog.setTitle,state.dialog,title()) end
    end
    local function schedule_refresh()
        if state.refresh_task then UI:unschedule(state.refresh_task) end
        local task
        task=function()
            if state.refresh_task~=task then return end
            state.refresh_task=nil;refresh()
        end
        state.refresh_task=task;UI:scheduleIn(.06,task)
    end
    local function change(id)
        if not footer_current() or not same_global_settings(footer) then close();return end
        local ok=Actions.activate(footer,id)
        if not ok and type(host.showInfo)=='function' then host:showInfo(_('Could not change the status bar. Check the current settings.')) end
        schedule_refresh()
    end
    local function visibility()
        if not footer_current() then close();return end
        local result=toggle_visibility(footer,view)
        if result==nil and type(host.showInfo)=='function' then host:showInfo(_('Enable a status item or the progress bar first.'))
        elseif not result and type(host.showInfo)=='function' then host:showInfo(_('Could not change the status bar. Check the current settings.')) end
        schedule_refresh()
    end
    local function toggle(id) return function() change(id) end end
    if not status_message then
        buttons[1]={item('visible',_('Status bar'),visibility),item('all_at_once',_('Show selected together'),toggle('all_at_once'))}
        buttons[2]={item('progress_bar',_('Progress bar'),toggle('progress_bar')),item('page_progress',_('Current page'),toggle('page_progress'))}
        buttons[3]={item('percentage',_('Reading percentage'),toggle('percentage')),item('chapter_time_to_read',_('Chapter time remaining'),toggle('chapter_time_to_read'))}
        buttons[4]={item('time',_('Current time'),toggle('time')),item('battery',_('Battery'),toggle('battery'))}
    end
    local function device_action(available,action)
        return function()
            if not current() then close();return end
            if not available() then return end
            close()
            action()
        end
    end
    if frontlight or eink_screen then
        local device_controls={}
        if frontlight then device_controls[#device_controls+1]={id='display_frontlight',text=_('Frontlight'),
            callback=device_action(has_frontlight,function() Device:showLightDialog() end)} end
        if eink_screen then device_controls[#device_controls+1]={id='display_full_refresh',text=_('Full screen refresh'),
            callback=device_action(has_eink_screen,function() UI:setDirty('all','full') end)} end
        buttons[#buttons+1]=device_controls
    end
    buttons[#buttons+1]={{id='display_close',text=_('Close'),callback=close}}
    local ok,dialog=pcall(function() return ButtonDialog:new{title=title(),buttons=buttons} end)
    if not ok or not dialog then M.cancel(host);return false end
    state.dialog=dialog
    local onclose=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if state.dialog==instance then state.dialog=nil;close() end
        if onclose then return onclose(instance,...) end
    end
    if not status_message then refresh() end
    if not state.dialog or not pcall(UI.show,UI,dialog) then M.cancel(host);return false end
    return true
end
return M
