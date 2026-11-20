-- Actual owner reader; only booleans leave the tmpfs profile.
return function(input,plugin,reader,pump,report)
    local UI=require('ui/uimanager')
    local util=require('weread.lib.plugin_util')
    local tr=util.tr
    local document=reader.document
    local before=document:getXPointer()
    local book=assert(plugin.settings:get_book(input.book_id))
    local chapters=assert(plugin:ensureChaptersLoaded(book))
    local index,chapter,full=plugin:getChapterInfoFromFile(book,document.file)
    assert(index and chapter and not full and tostring(chapter.chapterUid or chapter.chapterId)==input.chapter_uid)
    local prior,total,current=0,0,nil
    for i,row in ipairs(chapters) do
        local weight=tonumber(row.wordCount)
        assert(weight and weight>0 and weight%1==0)
        total=total+weight
        if i<index then prior=prior+weight end
        if i==index then current=weight end
    end
    assert(current and total>0)
    report.reader_estimate_stage=1
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do
        UI:close(UI:getTopmostVisibleWidget())
    end
    assert(plugin:onShowWeReadQuickMenu())
    UI:forceRePaint();local quick=assert(UI:getTopmostVisibleWidget())
    assert(quick:getButtonById('reader_progress')):onTapSelectButton()
    report.reader_estimate_stage=2
    pump(function() return plugin._weread_reader_progress~=nil end)
    local state=assert(plugin._weread_reader_progress)
    report.reader_estimate_stage=3
    assert(state.snapshot.document==document and state.snapshot.percent>=0 and state.snapshot.percent<=100)
    local expected=(prior+current*state.snapshot.percent/100)/total*100
    assert(type(state.whole_estimate)=='number' and math.abs(state.whole_estimate-expected)<1e-7)
    assert(math.abs(state.bar.bar.percentage-state.snapshot.percent/100)<1e-7)
    assert(state.dialog.title:find(tr('Current chapter file'),1,true))
    local label=util.T(tr('Whole book ≈ %1% (loaded catalog estimate)'),string.format('%.1f',expected))
    assert(state.dialog.title:find(label,1,true))
    assert(state.dialog.title:find(tr('The loaded catalog may be incomplete.'),1,true))
    assert(state.dialog:getContentSize().h<=require('device').screen:getHeight())
    report.reader_estimate_stage=4
    UI:forceRePaint()
    require('weread.ui.reader_progress').cancel(plugin)
    assert(not plugin._weread_reader_progress and document:getXPointer()==before)

    -- Exercise the production controls against the real chapter, without
    -- persisting a changed position in the isolated reading profile.
    local Event=require('ui/event')
    local Geom=require('ui/geometry')
    local function open_panel()
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do
            UI:close(UI:getTopmostVisibleWidget())
        end
        assert(plugin:onShowWeReadQuickMenu())
        UI:forceRePaint();local menu=assert(UI:getTopmostVisibleWidget())
        assert(menu:getButtonById('reader_progress')):onTapSelectButton()
        pump(function() return plugin._weread_reader_progress~=nil end)
        UI:forceRePaint()
        return assert(plugin._weread_reader_progress)
    end
    local pages=document:getPageCount()
    for _,ratio in ipairs({0,1}) do
        state=open_panel()
        local bar=state.bar;local d=bar.dimen
        local position=Geom:new{x=d.x+bar.inset+math.floor((d.w-2*bar.inset)*ratio),y=d.y+math.floor(d.h/2)}
        UI:sendEvent(Event:new('Gesture',{ges='tap',pos=position}))
        assert(state.task,'progress gesture was not accepted')
        pump(function() return not plugin._weread_reader_progress end)
        assert(reader:getCurrentPage()==(ratio==0 and 1 or pages),'progress endpoint opened the wrong page')
    end
    local original_handle=reader.handleEvent
    local requested
    reader.handleEvent=function(self,event,...)
        if event.handler=='onGotoPercent' then requested=event.args[1] end
        return original_handle(self,event,...)
    end
    state=open_panel()
    local expected_back=math.max(0,state.snapshot.percent-10)
    assert(state.dialog:getButtonById('progress_back_10')):onTapSelectButton()
    pump(function() return not plugin._weread_reader_progress end)
    local back=reader:getCurrentPage()
    assert(type(requested)=='number' and math.abs(requested-expected_back)<1e-7,'back ten percent sent the wrong target')
    if pages>=11 then assert(back<pages,'back ten percent did not move') end
    state=open_panel()
    local expected_forward=math.min(100,state.snapshot.percent+10);requested=nil
    assert(state.dialog:getButtonById('progress_forward_10')):onTapSelectButton()
    pump(function() return not plugin._weread_reader_progress end)
    assert(type(requested)=='number' and math.abs(requested-expected_forward)<1e-7,'forward ten percent sent the wrong target')
    if pages>=11 then assert(reader:getCurrentPage()>back,'forward ten percent did not move') end
    reader.handleEvent=original_handle
    state=open_panel()
    assert(state.dialog:getButtonById('progress_input')):onTapSelectButton()
    pump(function() return not plugin._weread_reader_progress end)
    assert(reader.gotopage.goto_dialog,'native page input did not open')
    reader.gotopage:close()
    reader.rolling:onGotoXPointer(before);UI:forceRePaint()
    assert(document:isXPointerInCurrentPage(before),'progress controls did not restore the original location')
    report.reader_estimate_stage=5
    return true
end
