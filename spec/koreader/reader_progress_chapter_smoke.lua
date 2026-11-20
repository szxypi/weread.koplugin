-- Exercise actual cross-file reader handoff with the synthetic book and server.
return function(reader,host,pump,clean,book_id)
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
    navigate(previous_host,'progress_next_chapter')
    pump(function() return Reader.instance and Reader.instance~=previous and Reader.instance.document.file==original_path end)
    reader=Reader.instance;host=reader.weread
    pump(function() return host.progress_sync.current_book_id==book_id end)
    reader.rolling:onGotoXPointer(original_point);UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(original_point),'return navigation lost the original native page')
    return reader,host
end
