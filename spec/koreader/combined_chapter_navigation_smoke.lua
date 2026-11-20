-- Packaged plugin, synthetic EPUB and mock service only.
return function(reader,host,book,id,pump,clean,set_offline)
    local Reader=require('apps/reader/readerui')
    local Content=require('weread.lib.content')
    local Identity=require('weread.lib.book_file_identity')
    local Dom=require('weread.lib.source_dom')
    local chapters=assert(host:ensureChaptersLoaded(book))
    local selected={chapters[2],chapters[4]}
    assert(selected[1].title==selected[2].title,'synthetic chapter titles differ')
    local original_path=reader.document.file
    local original_point=reader.document:getXPointer()
    local copy={};for key,value in pairs(book) do copy[key]=value end
    local png=require('mime').unb64('iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAAXElEQVR4nO3PsQ0AQAzCwOy/9P8EKVIZJFNTnOctm2Vp/ziQATTIABpkAA06B7RAz2FpIANokAE0yAAatP5roC0gA2iQATTIABp0DmiBnsPSQAbQIANokAE0aPt/y1n0pl3lRNkAAAAASUVORK5CYII=')
    local text2='<p>'..string.rep('这是第二章的合成正文。',100)..'</p>'
    local text4='<p>'..string.rep('这是第四章的合成正文。',100)..'</p>'
    local combined=Content.save_book_epub(host.settings,copy,selected,{['2']=text2,['4']=text4},
        'synthetic-navigation',{},'',png,Identity.capture(copy))
    -- A stale single-chapter mapping must not hide the verified combined EPUB.
    copy.cached_full_book=combined;copy.cached_file=combined
    copy.cached_chapters={['2']=combined,['4']=combined..'.missing'}
    copy.chapters=selected
    local saved=host.settings:get('books',{});saved[id]=copy;host.settings:set('books',saved);host.settings:flush()
    assert(host.library_db:putChapters(id,selected))
    pump(function() return host.progress_sync.current_book_id==id end)
    set_offline(true)
    local function select_chapter(current,selected_book,index)
        clean(current.ui);current:showChapterList(selected_book)
        pump(function() return current._chapter_list_view~=nil end)
        local view=assert(current._chapter_list_view)
        local row=assert(view._chapter_rows[index]);row.callback()
    end
    select_chapter(host,copy,2)
    pump(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==combined end)
    reader=assert(Reader.instance);host=assert(reader.weread)
    local target=assert(Dom.chapter_start(reader.document,id,'4'))
    pump(function() return reader.document:isXPointerInCurrentPage(target) end)
    local member=assert(Dom.member(reader.document,target))
    assert(member.render_path=='OEBPS/text/chapter-002.xhtml','handoff selected the wrong member')
    local original_reader=reader
    local latest=assert(host.settings:get_book(id));latest.chapters=selected
    select_chapter(host,latest,1)
    local first=assert(Dom.chapter_start(reader.document,id,'2'))
    pump(function() return reader.document:isXPointerInCurrentPage(first) end)
    assert(Reader.instance==original_reader,'same-file chapter selection reopened the reader')
    local first_member=assert(Dom.member(reader.document,first))
    assert(first_member.render_path=='OEBPS/text/chapter-001.xhtml','same-file selection chose the wrong member')
    select_chapter(host,latest,2);pump(function() return reader.document:isXPointerInCurrentPage(target) end)
    assert(Reader.instance==original_reader,'return selection reopened the reader')
    -- The same two-chapter EPUB is only a subset of the real six-chapter
    -- catalog. Navigation must keep the old pending position and stop sync.
    local before=assert(host.settings:get_book(id))
    local pending={book_id=id,chapter_uid=4,chapter_idx=4,chapter_offset=10,percent=50}
    local account=assert(host.library_db:accountKey())
    assert(host.settings:patch_reading_state(id,{pending_upload_position=pending,pending_upload_account=account}))
    assert(host.library_db:putChapters(id,chapters));latest.chapters=chapters
    -- Only chapters actually present in the partial EPUB are available.
    clean(reader);host:showChapterList(latest)
    pump(function() return host._chapter_list_view~=nil end)
    local catalog_view=assert(host._chapter_list_view)
    local cached=require('weread.lib.plugin_util').tr('Cached')
    for index,item in ipairs(catalog_view.chapters) do
        assert((item.status==cached)==(index==2 or index==4),'partial combined cache status was incorrect')
    end
    host:showChapterDownloadSelection(latest,chapters)
    local menu=assert(require('ui/uimanager'):getTopmostVisibleWidget())
    local row_index=0
    for _,item in ipairs(menu.item_table) do
        if not item.separator then
            row_index=row_index+1
            assert((item.mandatory_func()==cached)==(row_index==2 or row_index==4),
                'download selection cache status was incorrect')
        end
    end
    assert(row_index==#chapters,'download selection omitted a chapter')
    select_chapter(host,latest,2);pump(function() return reader.document:isXPointerInCurrentPage(first) end)
    assert(host.progress_sync.file_resume and host.progress_sync.file_resume.preserve_only,
        'partial combined file did not pause synchronization')
    assert(not host.progress_sync:checkpoint_local('synthetic_partial') and not host.progress_sync:sync_now(),
        'partial combined file allowed a whole-book progress update')
    local held=assert(host.settings:get_book(id))
    assert(held.pending_upload_position and tostring(held.pending_upload_position.chapter_uid)=='4'
        and held.pending_upload_position.chapter_offset==10 and held.pending_upload_account==account,
        'partial navigation changed the existing pending position')
    clean(reader)
    select_chapter(host,latest,4);pump(function() return reader.document:isXPointerInCurrentPage(target) end)
    assert(host.progress_sync.file_resume and host.progress_sync.file_resume.preserve_only)
    clean(reader)
    assert(host.settings:patch_reading_state(id,{pending_upload_position=before.pending_upload_position or false,
        pending_upload_account=before.pending_upload_account or false,last_local_position=before.last_local_position or false,
        last_local_account=before.last_local_account or false}))
    local restore=host.settings:get('books',{});restore[id]=book;host.settings:set('books',restore);host.settings:flush()
    assert(host.library_db:putChapters(id,chapters))
    host:openFile(original_path,function(next_reader)
        if next_reader.document:isXPointerInDocument(original_point) then next_reader.rolling:onGotoXPointer(original_point) end
    end)
    pump(function() return Reader.instance and Reader.instance~=original_reader and Reader.instance.document.file==original_path end)
    reader=assert(Reader.instance);host=assert(reader.weread)
    pump(function() return host.progress_sync.current_book_id==id end)
    assert(reader.document:isXPointerInCurrentPage(original_point),'test return lost the original reading position')
    set_offline(false)
    return reader,host
end
