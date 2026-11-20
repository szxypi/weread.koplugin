-- Exercise actual cross-file reader handoff with the synthetic book and server.
return function(reader,host,pump,clean,book_id,inspect_previous)
    local UI=require('ui/uimanager')
    local Reader=require('apps/reader/readerui')
    local original_path=reader.document.file
    local original_point=reader.document:getXPointer()
    local function navigate(active,button_id)
        clean(active.ui)
        assert(active:onShowWeReadQuickMenu())
        local quick=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
        assert(quick:getButtonById('reader_progress')):onTapSelectButton()
        pump(function() return active._weread_reader_progress~=nil end)
        local state=assert(active._weread_reader_progress);UI:forceRePaint()
        local button=assert(state.dialog:getButtonById(button_id));assert(button.enabled~=false)
        button:onTapSelectButton()
    end
    navigate(host,'progress_previous_chapter')
    pump(function()
        local current=Reader.instance
        local book=current and current.weread and current.weread.settings:get_book(book_id)
        return current and current~=reader and book and book.cached_chapters
            and current.document.file==book.cached_chapters['1']
    end)
    local previous=assert(Reader.instance);local previous_host=assert(previous.weread)
    pump(function() return previous_host.progress_sync.current_book_id==book_id end)
    if inspect_previous then inspect_previous(previous,previous_host) end
    -- Return through the quick menu's separate next-chapter action.
    clean(previous)
    assert(previous_host:onShowWeReadQuickMenu())
    local quick=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
    local list_button=assert(quick:getButtonById('chapter_list'));assert(list_button.enabled~=false)
    list_button:onTapSelectButton()
    pump(function() return previous_host._chapter_list_view~=nil end)
    assert(previous_host._chapter_list_view)
    clean(previous)
    -- The action is deferred after closing the menu. A new reader session
    -- before it runs must not open any chapter.
    assert(previous_host:onShowWeReadQuickMenu())
    quick=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
    local original_open=previous_host.openChapter
    local calls=0
    previous_host.openChapter=function() calls=calls+1 end
    assert(quick:getButtonById('next_chapter')):onTapSelectButton()
    local original_session=previous_host._reader_session_gen
    previous_host._reader_session_gen=(original_session or 0)+1
    local finished=false;UI:scheduleIn(.3,function() finished=true end)
    pump(function() return finished end)
    previous_host._reader_session_gen=original_session
    previous_host.openChapter=original_open
    assert(calls==0 and Reader.instance==previous,'stale next action opened a chapter')
    clean(previous)
    assert(previous_host:onShowWeReadQuickMenu())
    quick=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
    local next_button=assert(quick:getButtonById('next_chapter'));assert(next_button.enabled~=false)
    next_button:onTapSelectButton()
    pump(function() return Reader.instance and Reader.instance~=previous and Reader.instance.document.file==original_path end)
    reader=Reader.instance;host=reader.weread
    pump(function() return host.progress_sync.current_book_id==book_id end)
    reader.rolling:onGotoXPointer(original_point);UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(original_point),'return navigation lost the original native page')
    return reader,host
end
