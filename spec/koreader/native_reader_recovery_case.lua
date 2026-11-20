return function(reader,plugin,pump,clean,counters,pids,report)
    local json,UI=require('json'),require('ui/uimanager');local tr=require('weread.lib.plugin_util').tr
    local kind=report.kind;local closed=kind:match('^close%-')~=nil;local sync=plugin.progress_sync
    local timed=kind:match('^timer%-')~=nil
    local id=assert(plugin:detectWeReadBook());local pipeline=plugin.source_upload.native
    local Native=require('weread.lib.native_source_upload');local factory=Native.new
    local function observe(source)
        local prepare=source.prepare_current_native_preview
        source.prepare_current_native_preview=function(self,callback) counters[7]=counters[7]+1;return prepare(self,callback) end
    end
    local function wait(predicate)
        pump(function()
            for _i,worker in pairs({pipeline and pipeline.worker,pipeline and pipeline.source.worker,pipeline and pipeline.service.worker,
                plugin.native_renewal.worker,plugin.source_position.preview_worker}) do if worker.job then pids[worker.job.pid]=true end end
            return predicate()
        end)
    end
    local ok,why=pcall(function()
        local _,code=plugin.client:request{url='https://weread.qq.com/mock/native-recovery',method='POST',body=json.encode{mode=kind},
            headers={['Content-Type']='application/json'},skip_cookie=true,persist_response_cookies=false,sensitive=true};assert(code==200)
        if closed then
            Native.new=function(class,options) local value=factory(class,options);pipeline=value;observe(options.source);return value end
        else observe(plugin.source_position) end
        local request=plugin.client.request
        function plugin.client:request(options)
            if options.url=='https://i.weread.qq.com/login' then
                counters[6]=counters[6]+1
                local grant,revision,err,pending=plugin.native_renewal.store:read()
                assert(options.method=='POST' and not options.headers.Cookie and not options.headers.accessToken and not err
                    and grant and revision==2 and pending==true and not pipeline.service:pending(),'renew before durable intent or after data claim')
            elseif options.url=='https://i.weread.qq.com/book/read' and kind~='post' then
                local grant,revision,err,pending=plugin.native_renewal.store:read()
                assert(not err and not pending and revision==3 and grant.accessToken=='synthetic-renewed-access'
                    and options.headers.accessToken==grant.accessToken,'data sender used old grant')
            end
            local a,b,c=request(self,options)
            if tonumber(b)==401 then counters[8]=counters[8]+1 end
            return a,b,c
        end
        local save=plugin.native_renewal.store.save;local sync_file=plugin.native_renewal.store.sync
        if kind=='save' then plugin.native_renewal.store.save=function() return false,'save_failed' end end
        if kind=='save-sync' then
            plugin.native_renewal.store.sync=function(path)
                local record=plugin.native_renewal.store:_read()
                if record and record.revision==3 then return false end
                return sync_file(path)
            end
        end
        local timer=sync.interval;local clock=100
        if timed then
            timer.now=function() return clock end
            local config=plugin.settings:get('sync');config.upload_interval_minutes=1;plugin.settings:set('sync',config)
        end
        clean(reader);reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
        wait(function() return plugin.source_position:current()~=nil end)
        local point=assert(plugin.source_position:current());local before=assert(sync:capture_local())
        if closed then
            local doc=reader.document
            for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar','getXPointer','getCurrentPage','getPageCount'}) do
                local method=doc[name];doc[name]=function(self,...)
                    if counters[9]==1 then counters[10]=counters[10]+1;error('closed native document',0) end
                    return method(self,...)
                end
            end
            local config=plugin.settings:get('sync');config.upload_on_close=true;plugin.settings:set('sync',config)
            reader:onClose(false);counters[9]=1;report.closed=true
        elseif timed then
            clock=assert(timer.due);local task=assert(timer.task);UI:unschedule(task);task();report.timer_triggered=true
        else
            assert(plugin:onWeReadSyncProgress());wait(function() return not sync.pulling end)
            local dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.cancel_text==tr('Keep KOReader progress'))
            dialog.cancel_callback();UI:close(dialog)
        end
        if kind=='cancel' or kind=='offline' or kind=='account' or kind=='suspend' then
            wait(function() return plugin.native_renewal.job and plugin.native_renewal.worker and plugin.native_renewal.worker.job end)
            local pid=plugin.native_renewal.worker.job.pid;pids[pid]=true
            if kind=='offline' then
                plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline;plugin:onNetworkDisconnected()
            elseif kind=='account' then
                plugin.settings:update_auth({account={user_vid='900099',name='Synthetic'},cookies={wr_vid='900099',wr_skey='synthetic-new-cookie'},api_key=''},{replace_cookies=true})
                sync:on_account_changed();plugin.source_position:on_account_changed()
            elseif kind=='suspend' then plugin:onSuspend()
            else reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2) end
            wait(function() return not sync.uploading and not plugin.native_renewal.job end)
            wait(function() return require('ffi/util').isSubProcessDone(pid) end);report.cancelled=true
        else wait(function() return not sync.uploading and (not timed or not timer.cycle) end) end
        if kind=='save' or kind=='save-sync' then
            assert(plugin.native_renewal.job and plugin.native_renewal.job.state=='save_failed' and counters[0]==1 and counters[6]==1)
            plugin.native_renewal.store.save=save;plugin.native_renewal.store.sync=sync_file;plugin.native_authorization:renew()
            assert(not plugin.native_renewal.job and counters[6]==1,'save retry repeated authentication');report.save_only=true
            clean(reader);assert(plugin:onWeReadSyncProgress());wait(function() return not sync.pulling end)
            local dialog=assert(UI:getTopmostVisibleWidget());dialog.cancel_callback();UI:close(dialog);wait(function() return not sync.uploading end)
        end
        local success=kind=='snapshot' or kind=='prewrite' or kind=='feature' or kind=='save' or kind=='save-sync' or closed or timed
        local saved=plugin.settings:get_book(id);local row=pipeline.service:pending()
        if success then
            assert(counters[0]==2,'data count');assert(counters[6]==1,'auth count');assert(counters[7]==2,'source count')
            assert(not row,'position journal');assert(not saved.pending_upload_position,'pending local intent')
            assert(saved.last_uploaded_position.source_position.chapter_offset==point.chapter_offset,'uploaded source')
            assert(not saved.last_uploaded_position.summary,'summary persisted')
            assert(saved.last_local_position.chapter_offset==before.chapter_offset,'local checkpoint')
            report.confirmed,report.fresh_source=true,true
        elseif kind=='post' then
            assert(counters[0]==2 and counters[6]==0 and row.phase=='pending' and saved.pending_upload_position)
            report.unknown_not_replayed=true
        else
            assert(counters[0]==1 and counters[6]<=1 and not row and saved.pending_upload_position)
            report.local_kept=true
        end
        local grant,revision,err,pending=plugin.native_renewal.store:read()
        if kind=='account' then
            assert(not grant and not err,'foreign account read old grant')
            local raw=assert(plugin.native_renewal.store:_read());revision,pending=raw.revision,raw.renewal_pending
        else assert(grant and not err) end
        report.grant_revision,report.renewal_pending=revision,pending==true
        report.source_passes,report.auth_posts,report.expired_responses=tonumber(counters[7]),tonumber(counters[6]),tonumber(counters[8])
        if not closed then
            local config=plugin.settings:get('sync');config.upload_on_close=false;config.upload_interval_minutes=0;plugin.settings:set('sync',config);timer:reschedule()
            clean(reader);reader:onClose(false)
        end
        for pid in pairs(pids) do wait(function() return require('ffi/util').isSubProcessDone(pid) end) end
        assert(counters[10]==0);report.no_closed_document_calls,report.workers_reaped=true,true
    end)
    Native.new=factory
    if not ok then report.failed_line=tonumber(type(why)=='string' and why:match('native_reader_recovery_case%.lua:(%d+):')) or 0 end
    assert(ok,why)
end
