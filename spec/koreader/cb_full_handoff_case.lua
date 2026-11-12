-- Real cached full/single packages. No fabricated reader or source receipts.
return function(input,report,plugin,reader,pump,tick,position)
    local UI=require('ui/uimanager')
    local Reader=require('apps/reader/readerui')
    local Source=require('weread.lib.position_source')
    local full=reader.document.file
    local full_source=assert(Source.read_document(reader.document,input.book_id,input.chapter_uid))
    local original_co=position.chapter_offset
    local function clear()
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        plugin:closeWeReadUI()
    end
    local book=assert(plugin.settings:get_book(input.book_id))
    local chapter
    for _i,row in ipairs(assert(book.chapters or plugin.library_db:getChapters(input.book_id))) do
        if tostring(row.chapterUid)==input.chapter_uid then chapter=row;break end
    end
    assert(chapter)
    clear();plugin:openChapter(book,chapter)
    pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file~=full end)
    reader=Reader.instance;plugin=reader.weread
    pump(function() return plugin.progress_sync:current_source_target()~=nil end)
    local single=reader.document.file
    assert(assert(plugin.settings:get_book(input.book_id)).cached_chapters[input.chapter_uid]==single)
    local target=assert(plugin.progress_sync:current_source_target())
    local single_source=assert(Source.read_document(reader.document,input.book_id,input.chapter_uid))
    assert(single_source.raw_sha256==full_source.raw_sha256 and single_source.file_id~=full_source.file_id
        and target.chapter_offset==original_co and target.chapter_uid==input.chapter_uid and target.file_id==single_source.file_id)
    assert(plugin.progress_sync.verified==false and target.upload_verified==false)
    report.full_to_single=true;report.different_files=true;report.same_source=true
    clear();plugin:openFile(full,nil,assert(plugin.settings:get_book(input.book_id)))
    pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==full end)
    reader=Reader.instance;plugin=reader.weread
    pump(function() return plugin.progress_sync:current_source_target()~=nil end)
    target=assert(plugin.progress_sync:current_source_target())
    assert(target.chapter_offset==original_co and target.chapter_uid==input.chapter_uid
        and target.file_id==full_source.file_id and target.raw_sha256==single_source.raw_sha256)
    assert(plugin.progress_sync.verified==false and target.upload_verified==false)
    local index=assert(require('weread.lib.source_dom').open(reader.document,input.book_id,input.chapter_uid))
    local applied=assert(plugin.progress_sync.source_anchor)
    assert(applied.document==reader.document and reader.document:isXPointerInCurrentPage(applied.xpointer))
    assert(assert(index:capture(applied.xpointer)).co==original_co)
    report.single_to_full=true;report.position_preserved=true;report.cloud_unverified=true
    tick();UI:forceRePaint()
    return plugin,reader
end
