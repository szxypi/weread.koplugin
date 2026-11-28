-- Exercise actual cross-file reader handoff with the synthetic book and server.
return function(reader,host,pump,clean,book_id,inspect_previous,set_offline)
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
    if set_offline then
        local previous_path=assert(host.settings:get_book(book_id).cached_chapters['1'])
        local damaged=os.getenv('KO_HOME')..'/damaged-priority-chapter.epub'
        local file=assert(io.open(damaged,'wb'));assert(file:write('incomplete EPUB'));assert(file:close())
        local original_host=host
        local open_chapter=host.openChapter
        host.openChapter=function(self,selected,chapter,on_complete,options)
            assert(options and options.cached_only)
            local copies={}
            for uid,path in pairs(selected.cached_chapters) do copies[uid]=path end
            copies['1'],copies[1]=damaged,previous_path
            selected.cached_chapters=copies
            return open_chapter(self,selected,chapter,on_complete,options)
        end
        local function press_quick(active,id)
            clean(active.ui)
            assert(active:onShowWeReadQuickMenu())
            local menu=assert(UI:getTopmostVisibleWidget())
            local button=assert(menu:getButtonById(id));assert(button.enabled~=false)
            UI:forceRePaint();button:onTapSelectButton()
        end
        set_offline(true)
        press_quick(host,'previous_chapter')
        pump(function() return Reader.instance and Reader.instance.document.file==previous_path end)
        original_host.openChapter=open_chapter
        local neighbor=assert(Reader.instance)
        pump(function() return neighbor.weread.progress_sync.current_book_id==book_id end)
        assert(require('weread.lib.position_source').read_document(neighbor.document,book_id,1))
        press_quick(neighbor.weread,'next_chapter')
        pump(function() return Reader.instance and Reader.instance.document.file==original_path end)
        reader,host=Reader.instance,Reader.instance.weread
        pump(function() return host.progress_sync.current_book_id==book_id end)
        assert(reader.document:isXPointerInCurrentPage(original_point),'offline return lost the chapter page')
        set_offline(false)
        assert(os.remove(damaged))
    end
    if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then
        local tr=require('weread.lib.plugin_util').tr
        local record=assert(host.settings:get_book(book_id))
        local catalog=assert(host:ensureChaptersLoaded(record,true))
        local target=assert(catalog[6])
        local uid=tostring(target.chapterUid)
        assert(not record.cached_chapters[uid],'the stale-download fixture needs an uncached chapter')
        local function request()
            host:openChapter(record,target)
            local confirmation=assert(UI:getTopmostVisibleWidget())
            assert(confirmation.ok_text==tr('Download'))
            UI:close(confirmation)
            return confirmation.ok_callback
        end
        local page=reader.document:getCurrentPage()
        local other_page=page==1 and 2 or 1
        assert(reader.document:getPageCount()>1)
        local confirm=request()
        reader.rolling:onGotoPage(other_page)
        confirm()
        assert(not host.downloader._active_job,'a confirmation accepted after moving opened a download')
        reader.rolling:onGotoXPointer(original_point)
        request()()
        assert(host.downloader._active_job,'current confirmation did not start a download')
        reader.rolling:onGotoPage(other_page)
        pump(function()
            return not host.downloader._active_job and host.settings:get_book(book_id).cached_chapters[uid]
        end)
        assert(Reader.instance==reader and reader.document.file==original_path
            and reader.document:getCurrentPage()==other_page,'a late download changed the current reading location')
        clean(reader);reader.rolling:onGotoXPointer(original_point)
    end
    return reader,host
end
