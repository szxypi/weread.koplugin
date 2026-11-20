-- Actual KOReader reading events and widgets; synthetic content only.
return function(reader,host,pump,shot,clean,full)
    local UI=require('ui/uimanager')
    local Event=require('ui/event')
    local Geom=require('ui/geometry')
    local tr=require('weread.lib.plugin_util').tr
    local origin=reader.document:getXPointer()
    local mode=reader.view.view_mode
    if full then reader.rolling:onGotoPage(math.min(2,reader.document:getPageCount()));UI:forceRePaint() end
    local function open()
        clean(reader)
        assert(host:onShowWeReadQuickMenu())
        local quick=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
        assert(quick:getButtonById('reader_progress')):onTapSelectButton()
        pump(function() return host._weread_reader_progress~=nil end)
        local state=assert(host._weread_reader_progress)
        UI:forceRePaint()
        return state
    end
    local state=open()
    assert(state.dialog.title:find(tr(full and 'Current file' or 'Current chapter file'),1,true),
        'progress scope was mislabeled')
    assert(state.dialog:getContentSize().h<=require('device').screen:getHeight(), 'progress panel exceeds screen')
    shot(full and 'reader-progress-full' or 'reader-progress-chapter')
    local bar=state.bar;local d=bar.dimen
    local target=Geom:new{x=d.x+bar.inset+math.floor((d.w-2*bar.inset)*.85),y=d.y+math.floor(d.h/2)}
    UI:sendEvent(Event:new('Gesture',{ges='tap',pos=target}))
    assert(state.task,'tap did not route to the native progress bar')
    pump(function() return not host._weread_reader_progress end)
    assert(reader:getCurrentPage()>state.snapshot.page,'progress tap did not move the native reader')
    for _index,ratio in ipairs({0,1}) do
        state=open();bar=state.bar;d=bar.dimen
        target=Geom:new{x=d.x+bar.inset+math.floor((d.w-2*bar.inset)*ratio),y=d.y+math.floor(d.h/2)}
        UI:sendEvent(Event:new('Gesture',{ges='tap',pos=target}))
        assert(state.task,'endpoint tap did not reach the progress bar')
        pump(function() return not host._weread_reader_progress end)
        local expected=ratio==0 and 1 or reader.document:getPageCount()
        assert(reader:getCurrentPage()==expected,'progress endpoint did not reach the expected page')
    end
    reader.rolling:onGotoXPointer(origin);UI:forceRePaint()
    state=open()
    local input=assert(state.dialog:getButtonById('progress_input'));assert(input.enabled~=false)
    input:onTapSelectButton();pump(function() return not host._weread_reader_progress end)
    assert(reader.gotopage.goto_dialog,'native page input was not opened')
    reader.gotopage:close()
    state=open()
    if not full then
        local previous=assert(state.dialog:getButtonById('progress_previous_chapter'))
        assert(previous.enabled~=false,'previous chapter was not available')
        local original=host.openChapter;local selected
        host.openChapter=function(_,book,chapter) selected={book=book,chapter=chapter} end
        previous:onTapSelectButton();pump(function() return not host._weread_reader_progress end)
        host.openChapter=original
        assert(selected and tostring(selected.chapter.chapterUid)=='1','previous chapter targeted the wrong chapter')
    else
        local next_button=assert(state.dialog:getButtonById('progress_next_chapter'))
        assert(next_button.enabled~=false,'native full-file chapter navigation was unavailable')
        next_button:onTapSelectButton();pump(function() return not host._weread_reader_progress end)
        assert(reader:getCurrentPage()>state.snapshot.page,'native next chapter did not navigate')
        reader.rolling:onGotoXPointer(origin);UI:forceRePaint()
    end
    state=open()
    reader.rolling:onGotoPage(math.min(reader.document:getPageCount(),state.snapshot.page+1))
    pump(function() return not host._weread_reader_progress end)
    UI:forceRePaint()
    reader:handleEvent(Event:new('SetViewMode','scroll'));reader.rolling:onGotoXPointer(origin);UI:forceRePaint()
    state=open();assert(state.snapshot.mode=='scroll' and state.snapshot.percent>=0 and state.snapshot.percent<=100)
    local before=reader.document:getCurrentPos();bar=state.bar;d=bar.dimen
    target=Geom:new{x=d.x+bar.inset+math.floor((d.w-2*bar.inset)*.85),y=d.y+math.floor(d.h/2)}
    UI:sendEvent(Event:new('Gesture',{ges='tap',pos=target}));assert(state.task)
    pump(function() return not host._weread_reader_progress end)
    assert(reader.document:getCurrentPos()>before,'scroll progress did not move the native reader')
    open()
    host:onSuspend();assert(not host._weread_reader_progress,'suspend left progress dialog open')
    host:onResume();reader:handleEvent(Event:new('SetViewMode',mode));reader.rolling:onGotoXPointer(origin);UI:forceRePaint()
    clean(reader)
end
