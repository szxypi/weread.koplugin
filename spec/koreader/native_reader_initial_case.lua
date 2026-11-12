-- Actual packaged native ReaderUI, SQLite, memory workers and first-sync UI.
-- Synthetic-only caller; no Keychain or live authorization is available here.
return function(reader,plugin,pump,clean,counters,pids,report,reopen)
    local UI=require('ui/uimanager');local tr=require('weread.lib.plugin_util').tr
    local sync=plugin.progress_sync;local id=assert(plugin:detectWeReadBook())
    local mode=assert(os.getenv('WEREAD_NATIVE_INITIAL_CASE'))
    local confirmed=mode=='accepted' or mode=='delayed'
    local save_failed=mode=='local_save_failed'
    report.initial_case={mode=mode,reopen=reopen,cancelled_locally=false,explicit_choice=false,
        confirmed=false,unknown_kept=false,reviewed=false,local_save_failed=false,offline_preserved=false,
        no_automatic_write=false,workers_reaped=false,failed_line=0}
    local r=report.initial_case
    local function check_record()
        local journal=plugin.source_upload:_native().service.journal
        local row=journal:read();local saved=assert(plugin.settings:get_book(id))
        if confirmed then
            assert(row.phase=='idle' and saved.last_uploaded_position and not saved.pending_upload_position)
            local db=assert(plugin.library_db:open());local count=tonumber(db:rowexec('SELECT COUNT(*) FROM native_position_write_history'));db:close()
            assert(count==0)
        else
            assert(row.phase==(save_failed and 'verified' or mode=='changed_counts' and 'acknowledged' or 'pending'))
            assert(row.metadata.before.kind=='no_chapter' and row.metadata.before.chapter_idx==nil and row.metadata.desired.chapter_uid~='0')
            assert(saved.pending_upload_position and not saved.last_uploaded_position)
        end
    end
    if reopen then
        assert(not sync.is_online() and not sync.verified and not sync.interval.task)
        check_record();r.offline_preserved=true;clean(reader);reader:onClose(false);return
    end
    local config=plugin.settings:get('sync');config.upload_interval_minutes=1;config.upload_on_close=true
    plugin.settings:set('sync',config)
    clean(reader);reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
    pump(function() return plugin.source_position:current()~=nil end)
    sync:checkpoint_local('initial_local')
    local before=assert(sync:capture_local());local function choice()
        clean(reader);assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        local dialog=assert(UI:getTopmostVisibleWidget())
        assert(dialog.ok_text==tr('Sync current position') and dialog.cancel_text==tr('Keep KOReader progress'))
        assert(not sync.verified and not sync.uploading and not sync.interval.task and counters[0]==0 and counters[1]==0)
        return dialog
    end
    local dialog=choice();dialog.cancel_callback();UI:close(dialog)
    assert(not sync.verified and sync.state=='unverified' and not sync:prepare_close() and counters[0]==0)
    r.cancelled_locally=true
    dialog=choice();r.explicit_choice=true
    local persist=sync._persist
    if save_failed then
        sync._persist=function(self,book,patch)
            if patch.last_uploaded_position then error('initial/synthetic_local_save_failure',0) end
            return persist(self,book,patch)
        end
    end
    dialog.ok_callback();UI:close(dialog)
    pump(function() return not sync.uploading end);sync._persist=persist
    check_record()
    assert(counters[0]==1 and counters[1]==0)
    if confirmed then
        assert(sync.verified and sync.verified_reason=='first_sync_confirmed' and not sync.dirty)
        local saved=plugin.settings:get_book(id)
        assert(saved.last_uploaded_position.source_position.chapter_offset==before.source_position.chapter_offset
            and not saved.last_uploaded_position.summary and not saved.last_local_position.summary)
        r.confirmed=true
    else
        assert(not sync.verified and not sync.interval.task)
        r.unknown_kept=not save_failed;r.local_save_failed=save_failed
        -- Normal sync opens the existing read-only review, including an absent
        -- cloud chapter after rejection. Cancelling keeps receipt history intact.
        clean(reader);assert(plugin:onWeReadSyncProgress())
        local review=assert(UI:getTopmostVisibleWidget());assert(review.ok_text==tr('Check cloud position'))
        review.ok_callback()
        pump(function() local ctx=plugin._native_position_review_ui;return ctx and ctx.token end)
        local current=assert(UI:getTopmostVisibleWidget())
        assert(current.ok_text==tr('Archive and compare again'))
        if mode=='rejected' then assert(current.text:find(tr('WeRead has no chapter position for “%1”. Archiving keeps the old request result and your local position; it does not resend or undo anything. A delayed cloud change may still arrive.'):match('^(.-)%%1'),1,true)) end
        current.cancel_callback();UI:close(current);check_record();r.reviewed=true
    end
    assert(counters[0]==1 and counters[1]==0);r.no_automatic_write=true
    config.upload_interval_minutes=0;config.upload_on_close=false;plugin.settings:set('sync',config);sync.interval:reschedule()
    plugin.settings:flush();clean(reader);reader:onClose(false)
    for pid in pairs(pids) do pump(function() return require('ffi/util').isSubProcessDone(pid) end) end
    r.workers_reaped=next(pids)~=nil;assert(r.workers_reaped)
end
