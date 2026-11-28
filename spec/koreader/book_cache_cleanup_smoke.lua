-- Actual native dialogs, bounded deletion, retained records and a new download.
return function(reader,current,id,report,pump,tick,press,evidence,detail,close_reader)
    local UI=require('ui/uimanager')
    local Reader=require('apps/reader/readerui')
    local lfs=require('libs/libkoreader-lfs')
    local Crypto=require('weread.lib.crypto')
    local tr=require('weread.lib.plugin_util').tr
    local function read(path) local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close();return raw end
    local function write(path,raw) local file=assert(io.open(path,'wb'));assert(file:write(raw));file:close() end
    local function dismiss(base)
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=base do UI:close(UI:getTopmostVisibleWidget()) end
    end
    local function hold(menu,index)
        UI:forceRePaint()
        for _,item in ipairs(menu.item_group) do
            if item.entry==menu.item_table[index] then
                local dimen=assert(item[1].dimen)
                assert(item:onHoldSelect(nil,{pos={x=dimen.x+dimen.w/2,y=dimen.y+dimen.h/2}}))
                return
            end
        end
        error('chapter row is not visible')
    end
    local before=assert(current.progress_sync:current_source_target())
    local before_xpointer=assert(current.progress_sync.source_anchor).xpointer
    local before_page=reader:getCurrentPage()
    current:confirmClearBookCache(id,'Synthetic cache')
    assert(not current.book_cache_cleanup_job and Reader.instance==reader,'open book accepted for cleanup')
    dismiss(reader);close_reader()
    local host,view=detail()
    assert(view.data.status_line:find(tr('Full book cached'),1,true),'full book with two chapter files showed partial cache')
    UI:forceRePaint();require('device').screen:shot(evidence..'/cache-full-status.png')
    if host.source_close then host.source_close:cancel() end
    -- No real account data: this is an opaque synthetic pending-send journal.
    assert(host.settings:patch_reading_state(id,{source_dispatch={schema=1,id=string.rep('a',32)}}))
    local saved=assert(host.settings:get_book(id));local root=saved.cache_dir
    local state_path=root..'/.weread-accounts/'..host.settings:account_state_scope()..'/reading_state.json'
    local raw=read(state_path)
    local note_dir=root..'/synthetic.sdr';assert(lfs.mkdir(note_dir))
    write(note_dir..'/metadata.epub.lua','return { annotation = "Synthetic local note" }')
    local note_hash=Crypto.sha256_hex(read(note_dir..'/metadata.epub.lua'))
    local pending=require('weread.lib.translation_resume'):new(host.library_db,host.client,host.settings:get_auth_scope())
    local token=assert(pending:begin(id,string.rep('a',64),{{chapterUid=1,title='Synthetic'}},7,false))
    assert(pending:put(token,'1','<p>Synthetic incomplete translation</p>'))
    for i=1,80 do write(root..'/cache-extra-'..string.format('%03d',i)..'.bin','Synthetic removable resource') end
    local function records()
        assert(read(state_path)==raw,'cleanup rewrote the reading journal')
        assert(Crypto.sha256_hex(read(note_dir..'/metadata.epub.lua'))==note_hash,'cleanup removed local notes')
        assert(host.settings:get_book(id).cache_dir==root,'cleanup dropped the pinned record directory')
    end
    local full=assert(saved.cached_full_book)
    local full_bytes=read(full)
    local metadata_path=root..'/metadata.json'
    local metadata_before=read(metadata_path)
    local first,second=assert(saved.cached_chapters['2']),assert(saved.cached_chapters['4'])
    local first_bytes,second_bytes=read(first),read(second)
    press(view,'Downloaded chapters')
    local picker=assert(host._saved_chapter_menu)
    assert(#picker.item_table==6,'full copy did not provide all six chapters')
    hold(picker,1)
    assert(not host.book_cache_cleanup_job and read(full)==full_bytes,'chapter inside the whole book offered removal')
    dismiss(picker)
    hold(picker,2)
    local chapter_job=assert(host.book_cache_cleanup_job)
    assert(chapter_job.copy.path==first and chapter_job.copy.chapter_uid=='2' and chapter_job.bytes==#first_bytes)
    chapter_job.dialog:onClose();records()
    assert(read(first)==first_bytes and not host.book_cache_cleanup_job,'cancel removed the single chapter')
    hold(picker,2)
    assert(host.book_cache_cleanup_job).dialog.ok_callback()
    pump(function() return not host.book_cache_cleanup_job end);records()
    saved=assert(host.settings:get_book(id))
    assert(not lfs.attributes(first) and read(second)==second_bytes and read(full)==full_bytes
        and not saved.cached_chapters['2'] and saved.cached_chapters['4']==second and saved.cached_full_book==full
        and pending:get(token,'1'),'single chapter cleanup modified unrelated downloads or lost its metadata')
    view=assert(host._book_detail_view)
    dismiss(view)
    press(view,'Downloaded chapters');picker=assert(host._saved_chapter_menu)
    assert(#picker.item_table==6,'removed standalone chapter disappeared despite being in the full copy')
    hold(picker,2)
    assert(not host.book_cache_cleanup_job and read(full)==full_bytes,'removed chapter still offered cleanup')
    dismiss(picker);UI:close(picker)
    write(first,first_bytes);write(metadata_path,metadata_before)
    report.cache_single_chapter_selective=true
    press(view,'Remove only the full-book copy')
    local selective=assert(host.book_cache_cleanup_job)
    assert(selective.files==1 and selective.bytes==#full_bytes,'selective preview did not match the full copy')
    selective.dialog:onClose();records()
    assert(read(full)==full_bytes and not host.book_cache_cleanup_job,'cancelled selective cleanup removed the copy')
    press(view,'Remove only the full-book copy')
    assert(host.book_cache_cleanup_job).dialog.ok_callback()
    pump(function() return not host.book_cache_cleanup_job end);records()
    assert(not lfs.attributes(full) and read(first)==first_bytes and read(second)==second_bytes,
        'selective cleanup removed the wrong EPUB')
    assert(pending:get(token,'1') and lfs.attributes(root..'/cache-extra-001.bin'),
        'selective cleanup removed other download data')
    saved=assert(host.settings:get_book(id))
    assert(not saved.cached_full_book and not saved.cached_file and saved.cached_chapters['2']==first and saved.cached_chapters['4']==second)
    view=assert(host._book_detail_view)
    assert(not view.data.status_line:find(tr('Full book cached'),1,true),'detail still showed the removed copy')
    local Common=require('weread.ui.common')
    local Client=require('weread.lib.client')
    local online,connected,request=Common.isNetworkOnline,Common.isNetworkConnected,Client.request
    Common.isNetworkOnline=function() return false end
    Common.isNetworkConnected=Common.isNetworkOnline
    local requests=0
    Client.request=function() requests=requests+1;error('offline chapter requested network access') end
    press(view,'Downloaded chapters')
    picker=assert(host._saved_chapter_menu)
    assert(#picker.item_table==2,'downloaded picker did not list the two retained chapters')
    picker:onMenuSelect(picker.item_table[1])
    pump(function() return Reader.instance and Reader.instance.document.file==first end)
    assert(require('weread.lib.position_source').read_document(Reader.instance.document,id,2),'wrong retained chapter opened')
    close_reader()
    Common.isNetworkOnline,Common.isNetworkConnected,Client.request=online,connected,request
    assert(requests==0,'opening the retained chapter required network access')
    report.cache_full_copy_selective=true
    report.cache_selective_offline_chapter=true
    -- Restore the download before opening details, then restore the earlier
    -- synthetic journal after the second reader's close work is cancelled.
    write(full,full_bytes);write(metadata_path,metadata_before)
    host,view=detail()
    if host.source_close then host.source_close:cancel() end
    write(state_path,raw);records()
    host:confirmClearBookCache(id,'Synthetic cache');local job=assert(host.book_cache_cleanup_job)
    local dialog=assert(job.dialog);assert(UI:getTopmostVisibleWidget()==dialog)
    UI:forceRePaint();require('device').screen:shot(evidence..'/cache-clear-confirmation.png')
    dialog:onClose();records();assert(not host.book_cache_cleanup_job,'cancelled confirmation survived')
    assert(pending:get(token,'1'),'cancelled confirmation removed the unfinished translation')
    host:confirmClearBookCache(id,'Synthetic cache');job=assert(host.book_cache_cleanup_job)
    job.dialog.ok_callback()
    pump(function() return job.items[1].deletion and job.items[1].deletion.files>=32 end)
    assert(host.book_cache_cleanup_job==job,'cleanup did not yield before completion')
    local busy=assert(host.busy_message);assert(UI:getTopmostVisibleWidget()==busy)
    UI:forceRePaint();require('device').screen:shot(evidence..'/cache-clear-cancellation.png')
    busy:onTapClose();assert(not host.book_cache_cleanup_job);records()
    assert(pending:get(token,'1'),'stopped cleanup removed the unfinished translation')
    dismiss(view)
    local count=job.items[1].deletion.files
    for _i=1,12 do tick() end
    assert(job.items[1].deletion.files==count,'cancelled cleanup continued')
    host:confirmClearBookCache(id,'Synthetic cache');job=assert(host.book_cache_cleanup_job)
    job.dialog.ok_callback();pump(function() return not host.book_cache_cleanup_job end);records()
    assert(not pending:get(token,'1') and not pending:token(id).generation,'completed cleanup kept unfinished translation')
    saved=assert(host.settings:get_book(id));assert(not saved.cached_full_book and not saved.cached_file and not next(saved.cached_chapters or {}))
    dismiss(view)
    host,view=detail();press(view,'⇩ Download full book')
    pump(function() return Reader.instance and Reader.instance.weread.progress_sync.current_book_id==id end)
    reader,current=Reader.instance,Reader.instance.weread
    local metadata=assert(require('weread.lib.position_source').document_metadata(reader.document,id,before.chapter_uid)).record
    local restored_xpointer
    if metadata.file_id==before.file_id then
        -- Identical package identity uses KOReader's retained native .sdr point;
        -- no cross-file resume anchor is expected in this branch.
        assert(reader:getCurrentPage()==before_page and reader.document:isXPointerInCurrentPage(before_xpointer))
        local index=assert(require('weread.lib.source_dom').open(reader.document,id,before.chapter_uid))
        assert(assert(index:capture(before_xpointer)).co==before.chapter_offset)
        restored_xpointer=before_xpointer
    else
        pump(function() return current.progress_sync:current_source_target()~=nil end)
        local after=assert(current.progress_sync:current_source_target())
        assert(after.chapter_uid==before.chapter_uid and after.chapter_offset==before.chapter_offset and after.raw_sha256==before.raw_sha256,
            'new full download did not restore the retained source position')
        restored_xpointer=assert(current.progress_sync.source_anchor).xpointer
    end
    assert(current.settings:get_book(id).source_dispatch,'new download lost the pending-send journal')
    assert(Crypto.sha256_hex(read(note_dir..'/metadata.epub.lua'))==note_hash)
    report.cache_open_book_excluded=true;report.cache_confirmation_cancelled=true
    report.cache_chunk_cancelled=true;report.cache_cancelled_files=count
    report.cache_reading_journal_bytes_retained=true;report.cache_native_notes_retained=true
    report.cache_indexes_retained=true;report.cache_redownload_source_position_restored=true
    report.cache_full_status_verified=true
    dismiss(reader);tick()
    return reader,current,restored_xpointer
end
