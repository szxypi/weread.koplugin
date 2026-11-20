-- Actual owner reader; private chapter contents remain in the tmpfs profile.
return function(input,host,reader,pump)
    local UI=require('ui/uimanager')
    local Reader=require('apps/reader/readerui')
    local Source=require('weread.lib.position_source')
    local tr=require('weread.lib.plugin_util').tr
    local original=reader.document.file
    local point=reader.document:getXPointer()
    local book=assert(host.settings:get_book(input.book_id))
    local chapters=assert(host:ensureChaptersLoaded(book))
    local index=assert(host:getChapterInfoFromFile(book,original))
    local neighbor=input.reader_neighbor
    local row=assert(chapters[index+neighbor.direction])
    assert(tostring(row.chapterUid or row.chapterId)==neighbor.uid,'adjacent catalog changed')
    local function select(active,direction)
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=active.ui do
            UI:close(UI:getTopmostVisibleWidget())
        end
        assert(active:onShowWeReadQuickMenu())
        UI:forceRePaint()
        assert(UI:getTopmostVisibleWidget():getButtonById('reader_progress')):onTapSelectButton()
        pump(function() return active._weread_reader_progress~=nil end)
        local state=assert(active._weread_reader_progress)
        local button=assert(state.dialog:getButtonById(direction==1 and 'progress_next_chapter' or 'progress_previous_chapter'))
        assert(button.enabled~=false,'adjacent chapter button disabled')
        button:onTapSelectButton()
    end
    local function wait_for_open(previous)
        pump(function()
            local top=UI:getTopmostVisibleWidget()
            if top and type(top.ok_callback)=='function' and (top.ok_text==tr('Download') or top.ok_text==tr('Read now')) then
                top.ok_callback();UI:close(top)
            end
            return Reader.instance and Reader.instance~=previous and Reader.instance.document
        end)
        local next_reader=assert(Reader.instance)
        return assert(next_reader.weread),next_reader
    end
    select(host,neighbor.direction)
    local next_host,next_reader=wait_for_open(reader)
    assert(next_reader.document.file~=original,'adjacent chapter did not open a new file')
    local neighbor_path=next_reader.document.file
    local source=assert(Source.read_document(next_reader.document,input.book_id,neighbor.uid))
    assert(source.raw_sha256==neighbor.raw_sha256,'adjacent chapter source does not match independent read')
    select(next_host,-neighbor.direction)
    host,reader=wait_for_open(next_reader)
    assert(reader.document.file==original,'return did not reopen original chapter')
    reader.rolling:onGotoXPointer(point);UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(point),'return did not restore original visible position')

    -- Test the separate quick-menu entry from whichever chapter has a next
    -- neighbor, while reusing only the two previously verified files.
    if neighbor.direction==-1 then
        select(host,-1)
        host,reader=wait_for_open(reader)
        assert(reader.document.file==neighbor_path,'could not return to the previous chapter')
    end
    pump(function() return host.progress_sync.current_book_id==input.book_id end)
    local function quick()
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do
            UI:close(UI:getTopmostVisibleWidget())
        end
        assert(host:onShowWeReadQuickMenu());UI:forceRePaint()
        return assert(UI:getTopmostVisibleWidget())
    end
    local menu=quick()
    local list=assert(menu:getButtonById('chapter_list'));assert(list.enabled~=false)
    list:onTapSelectButton()
    pump(function() return host._chapter_list_view~=nil end)
    local view=assert(host._chapter_list_view)
    assert(type(view.chapters)=='table' and #view.chapters==#chapters,'quick-menu chapter list was incomplete')
    local listed,original_listed=false,false
    for _,item in ipairs(view.chapters) do
        local chapter=item.source
        local uid=chapter and tostring(chapter.chapterUid or chapter.chapterId)
        if uid==neighbor.uid then
            listed=true;assert(item.status==tr('Cached'),'downloaded neighbor was not marked cached')
        elseif uid==input.chapter_uid then
            original_listed=true;assert(item.status==tr('Cached'),'original chapter was not marked cached')
        end
    end
    assert(listed and original_listed,'quick-menu chapter list omitted a verified chapter')
    menu=quick()
    local original_open=host.openChapter
    local calls=0
    host.openChapter=function() calls=calls+1 end
    assert(menu:getButtonById('next_chapter')):onTapSelectButton()
    local old_session=host._reader_session_gen
    host._reader_session_gen=(old_session or 0)+1
    local done=false;UI:scheduleIn(.3,function() done=true end)
    pump(function() return done end)
    host._reader_session_gen=old_session;host.openChapter=original_open
    assert(calls==0 and Reader.instance==reader,'stale quick-menu action opened a chapter')
    menu=quick()
    local next_button=assert(menu:getButtonById('next_chapter'));assert(next_button.enabled~=false)
    next_button:onTapSelectButton()
    next_host,next_reader=wait_for_open(reader)
    if neighbor.direction==1 then
        assert(next_reader.document.file==neighbor_path,'quick-menu next chapter did not open')
        local checked=assert(Source.read_document(next_reader.document,input.book_id,neighbor.uid))
        assert(checked.raw_sha256==neighbor.raw_sha256,'quick-menu next chapter source changed')
        select(next_host,-1)
        host,reader=wait_for_open(next_reader)
    else
        host,reader=next_host,next_reader
    end
    assert(reader.document.file==original,'quick-menu navigation did not return to the original chapter')
    reader.rolling:onGotoXPointer(point);UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(point),'quick-menu navigation lost the original visible position')
    return host,reader
end
