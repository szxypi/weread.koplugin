-- Native progress panel: navigation always targets the open file.
local ButtonDialog=require('ui/widget/buttondialog')
local Device=require('device')
local Event=require('ui/event')
local Geom=require('ui/geometry')
local GestureRange=require('ui/gesturerange')
local InputContainer=require('ui/widget/container/inputcontainer')
local ProgressWidget=require('ui/widget/progresswidget')
local UI=require('ui/uimanager')
local Context=require('weread.lib.reader_progress_context')
local util=require('weread.lib.plugin_util')
local _=util.tr
local Screen=Device.screen
local M={}

local Bar=InputContainer:extend{dimen=nil,bar=nil,callback=nil}
function Bar:init()
    self.ges_events={TapSelect={GestureRange:new{ges='tap',range=self.dimen}}}
end
function Bar:getSize() return Geom:new{w=self.dimen.w,h=self.dimen.h} end
function Bar:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    self.bar:paintTo(bb,x+self.inset,y+math.floor((self.dimen.h-self.bar.height)/2))
end
function Bar:onTapSelect(_arg,gesture)
    local pos=gesture and gesture.pos
    if not pos or type(pos.x)~='number' then return true end
    local ratio=(pos.x-self.dimen.x-self.inset)/math.max(1,self.dimen.w-2*self.inset)
    self.callback(math.max(0,math.min(100,ratio*100)))
    return true
end

function M.cancel(host)
    local state=host and host._weread_reader_progress
    if not state then return end
    host._weread_reader_progress=nil
    if state.task then UI:unschedule(state.task);state.task=nil end
    if state.dialog then local dialog=state.dialog;state.dialog=nil;UI:close(dialog) end
end
function M.show(host,options)
    options=options or {}
    local snapshot=Context.capture(host)
    if not snapshot then
        M.cancel(host)
        if host and type(host.showInfo)=='function' then host:showInfo(_('Reading progress is unavailable for this file.')) end
        return false
    end
    if options.is_current then
        local ok,valid=pcall(options.is_current)
        if not ok or valid~=true then return false end
    end
    M.cancel(host)
    if not Context.current(host,snapshot) then return false end
    local ui=snapshot.ui
    local state={snapshot=snapshot};host._weread_reader_progress=state
    local function current()
        if host._weread_reader_progress~=state or not Context.current(host,snapshot) then return false end
        if options.is_current then
            local ok,valid=pcall(options.is_current)
            if not ok or valid~=true then return false end
        end
        return true
    end
    local function finish(action)
        if not current() then
            if host._weread_reader_progress==state then M.cancel(host) end
            return
        end
        local dialog=state.dialog;state.dialog=nil
        if dialog then UI:close(dialog) end
        if not action then host._weread_reader_progress=nil;return end
        state.task=function()
            state.task=nil
            if not current() then
                if host._weread_reader_progress==state then M.cancel(host) end
                return
            end
            host._weread_reader_progress=nil
            action()
        end
        UI:scheduleIn(.1,state.task)
    end
    local function goto_percent(percent)
        if type(percent)~='number' or percent~=percent then return end
        percent=math.max(0,math.min(100,percent))
        finish(function()
            if ui.link and type(ui.link.addCurrentLocationToStack)=='function' then ui.link:addCurrentLocationToStack() end
            ui:handleEvent(Event:new('GotoPercent',percent))
        end)
    end
    local function native_chapter(direction)
        finish(function() ui:handleEvent(Event:new(direction<0 and 'GotoPrevChapter' or 'GotoNextChapter')) end)
    end
    local prev,next_chapter=options.previous,options.next
    local can_open=type(host.openChapter)=='function' and type(options.resolve_chapter)=='function'
    local function open_chapter(direction)
        finish(function()
            local ok,book,chapter=pcall(options.resolve_chapter,direction)
            if ok and book and chapter then host:openChapter(book,chapter)
            elseif type(host.showInfo)=='function' then host:showInfo(_('Chapter information changed. Open the progress panel again.')) end
        end)
    end
    local prev_action,next_action
    if can_open and prev then prev_action=function() open_chapter(-1) end end
    if can_open and next_chapter then next_action=function() open_chapter(1) end end
    if options.native_chapters and type(ui.toc)=='table' then
        local function has_target(method)
            if type(ui.toc[method])~='function' then return false end
            local ok,target=pcall(ui.toc[method],ui.toc,snapshot.page)
            return ok and type(target)=='number' and target>0
        end
        if has_target('getPreviousChapter') then prev_action=function() native_chapter(-1) end end
        if has_target('getNextChapter') then next_action=function() native_chapter(1) end end
    end
    local gotopage=ui.gotopage
    local can_input=gotopage and type(gotopage.onShowGotoDialog)=='function'
    local scope=options.single_chapter and _('Current chapter file') or _('Current file')
    local heading=util.T(_('%1 · page %2 / %3 · %4%'),scope,snapshot.page,snapshot.total,
        string.format('%.1f',snapshot.percent))
    if options.single_chapter then
        local ok,estimate=pcall(require('weread.lib.reader_whole_estimate').for_document,
            snapshot.document,options.book,options.chapters,options.chapter_index,options.chapter_uid,snapshot.percent)
        if ok and estimate then
            state.whole_estimate=estimate
            heading=heading..'\n'..util.T(_('Whole book ≈ %1% (loaded catalog estimate)'),string.format('%.1f',estimate))
            heading=heading..'\n'.._('The loaded catalog may be incomplete.')
        else
            heading=heading..'\n'.._('Whole-book estimate unavailable.')
        end
    end
    local built,dialog=pcall(function()
        local window=ButtonDialog:new{title=heading,buttons={
            {{id='progress_previous_chapter',text=_('Previous chapter'),enabled=prev_action~=nil,callback=prev_action},
             {id='progress_next_chapter',text=_('Next chapter'),enabled=next_action~=nil,callback=next_action}},
            {{id='progress_back_10',text='−10%',callback=function() goto_percent(snapshot.percent-10) end},
             {id='progress_forward_10',text='+10%',callback=function() goto_percent(snapshot.percent+10) end}},
            {{id='progress_input',text=_('Enter page or percentage'),enabled=can_input and true or false,
                callback=function() finish(function()
                    if ui.gotopage==gotopage then gotopage:onShowGotoDialog() end
                end) end}},
            {{text=_('Close'),callback=function() finish(nil) end}},
        }}
        state.dialog=window
        local previous_close=window.onCloseWidget
        window.onCloseWidget=function(instance,...)
            if state.dialog==instance then
                state.dialog=nil
                if host._weread_reader_progress==state then M.cancel(host) end
            end
            if previous_close then return previous_close(instance,...) end
        end
        local width=window:getAddedWidgetAvailableWidth()
        local inset=Screen:scaleBySize(12)
        local height=Screen:scaleBySize(48)
        local bar=ProgressWidget:new{width=math.max(1,width-2*inset),height=Screen:scaleBySize(12),percentage=snapshot.percent/100}
        local touch=Bar:new{dimen=Geom:new{w=width,h=height},inset=inset,bar=bar,callback=goto_percent}
        window:addWidget(touch)
        state.bar=touch
        return window
    end)
    if not built or not dialog then
        state.dialog=nil;M.cancel(host)
        if type(host.showInfo)=='function' then host:showInfo(_('Could not open reading progress.')) end
        return false
    end
    local shown=pcall(UI.show,UI,dialog)
    if not shown then
        state.dialog=nil;M.cancel(host);pcall(UI.close,UI,dialog)
        if type(host.showInfo)=='function' then host:showInfo(_('Could not open reading progress.')) end
        return false
    end
    return true
end
return M
