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
    local source=assert(Source.read_document(next_reader.document,input.book_id,neighbor.uid))
    assert(source.raw_sha256==neighbor.raw_sha256,'adjacent chapter source does not match independent read')
    select(next_host,-neighbor.direction)
    host,reader=wait_for_open(next_reader)
    assert(reader.document.file==original,'return did not reopen original chapter')
    reader.rolling:onGotoXPointer(point);UI:forceRePaint()
    assert(reader.document:isXPointerInCurrentPage(point),'return did not restore original visible position')
    return host,reader
end
