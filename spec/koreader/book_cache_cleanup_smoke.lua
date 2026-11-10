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
    local raw=read(root..'/reading_state.json')
    local note_dir=root..'/synthetic.sdr';assert(lfs.mkdir(note_dir))
    write(note_dir..'/metadata.epub.lua','return { annotation = "Synthetic local note" }')
    local note_hash=Crypto.sha256_hex(read(note_dir..'/metadata.epub.lua'))
    for i=1,80 do write(root..'/cache-extra-'..string.format('%03d',i)..'.bin','Synthetic removable resource') end
    local function records()
        assert(read(root..'/reading_state.json')==raw,'cleanup rewrote the reading journal')
        assert(Crypto.sha256_hex(read(note_dir..'/metadata.epub.lua'))==note_hash,'cleanup removed local notes')
        assert(host.settings:get_book(id).cache_dir==root,'cleanup dropped the pinned record directory')
    end
    host:confirmClearBookCache(id,'Synthetic cache');local job=assert(host.book_cache_cleanup_job)
    local dialog=assert(job.dialog);assert(UI:getTopmostVisibleWidget()==dialog)
    UI:forceRePaint();require('device').screen:shot(evidence..'/cache-clear-confirmation.png')
    dialog:onClose();records();assert(not host.book_cache_cleanup_job,'cancelled confirmation survived')
    host:confirmClearBookCache(id,'Synthetic cache');job=assert(host.book_cache_cleanup_job)
    job.dialog.ok_callback()
    pump(function() return job.items[1].deletion and job.items[1].deletion.files>=32 end)
    assert(host.book_cache_cleanup_job==job,'cleanup did not yield before completion')
    local busy=assert(host.busy_message);assert(UI:getTopmostVisibleWidget()==busy)
    UI:forceRePaint();require('device').screen:shot(evidence..'/cache-clear-cancellation.png')
    busy:onTapClose();assert(not host.book_cache_cleanup_job);records()
    dismiss(view)
    local count=job.items[1].deletion.files
    for _i=1,12 do tick() end
    assert(job.items[1].deletion.files==count,'cancelled cleanup continued')
    host:confirmClearBookCache(id,'Synthetic cache');job=assert(host.book_cache_cleanup_job)
    job.dialog.ok_callback();pump(function() return not host.book_cache_cleanup_job end);records()
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
