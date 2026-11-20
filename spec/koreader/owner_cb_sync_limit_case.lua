-- Normal CB_ reading and offline reopen remain available; Sync does no work
-- for an unverified cloud coordinate basis, even with automatic sync enabled.
return function(input,mode,counters)
    local UI=require('ui/uimanager');local tr=require('weread.lib.plugin_util').tr
    local case={report={notice=false,local_checkpoint=false,unverified=false,pending_preserved=false,
        timer_stopped=false,zero_sync_requests=false,native_denied=0,failed_line=0}}
    function case:is_native(o) return type(o.url)=='string' and o.url:find('https://i.weread.qq.com/',1,true)==1 end
    function case:request() counters[23]=counters[23]+1;error('cb_sync/native_forbidden',0) end
    function case:run(plugin,reader,pump)
        local sync,source=plugin.progress_sync,plugin.source_position
        local point=assert(source:current());assert(point.book_id==input.book_id and not sync.verified)
        local config=plugin.settings:get('sync');config.upload_interval_minutes=1;config.upload_on_close=true;config.pull_on_open=true
        plugin.settings:set('sync',config);sync.dirty=true;sync:checkpoint_local('cb_limit_local')
        local function requests() local n=0;for _i=0,6 do n=n+tonumber(counters[_i]) end;return n end
        local saved=assert(plugin.settings:get_book(input.book_id));local pending=assert(saved.pending_upload_position.source_position)
        assert(pending.chapter_offset==point.chapter_offset)
        for _i=1,2 do
            while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
            local before=requests();plugin:onWeReadSyncProgress();pump(function() return not sync.pulling and not sync.uploading end)
            local message=assert(UI:getTopmostVisibleWidget())
            assert(message.text==tr('Cloud progress sync is not supported for this book yet. Your local reading position is kept.'))
            assert(not message.ok_callback and not message.cancel_callback);UI:close(message)
            assert(requests()==before and counters[23]==0 and not sync.verified and sync.state=='unverified'
                and not sync.interval.task and not sync.interval.cycle)
            saved=assert(plugin.settings:get_book(input.book_id))
            assert(saved.pending_upload_position.source_position.chapter_offset==point.chapter_offset
                and saved.last_local_position.source_position.chapter_offset==point.chapter_offset
                and saved.last_sync_error=='progress_book_sync_unsupported' and not saved.last_uploaded_position)
        end
        self.report.notice,self.report.local_checkpoint,self.report.unverified=true,true,true
        self.report.pending_preserved,self.report.timer_stopped,self.report.zero_sync_requests=true,true,true
        config.upload_interval_minutes=0;config.upload_on_close=false;plugin.settings:set('sync',config)
        assert((mode=='reopen')==not plugin:isNetworkOnline())
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then assert(not content:find(input.source_text,1,true)) end
    end
    function case:private() return nil end
    function case:finish(reason)
        self.report.native_denied=tonumber(counters[23])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_cb_sync_limit_case%.lua:(%d+):')) or 0
    end
    return case
end
