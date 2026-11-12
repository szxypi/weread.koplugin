-- Normal Sync UI, real SQLite/worker, loopback unknown request; no owner data.
return function(reader,plugin,pump,clean,counters,pids,report)
    local json,UI=require('json'),require('ui/uimanager');local tr=require('weread.lib.plugin_util').tr
    local kind=report.kind;local sync=plugin.progress_sync;local id=assert(plugin:detectWeReadBook())
    local function wait(predicate)
        pump(function()
            local ctx=plugin._native_position_review_ui;local worker=ctx and ctx.task.worker
            for _i,value in pairs({worker,plugin.cloud_source_worker,plugin.source_navigation.worker}) do
                if value.job then pids[value.job.pid]=true end
            end
            return predicate()
        end)
    end
    local function move()
        clean(reader);reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
        wait(function() return plugin.source_position:current()~=nil end)
    end
    local function control(mode)
        local _,code=plugin.client:request{url='https://weread.qq.com/mock/native-control',method='POST',body=json.encode{mode=mode},
            headers={['Content-Type']='application/json'},skip_cookie=true,persist_response_cookies=false,sensitive=true};assert(code==200)
    end
    local ok,why=pcall(function()
        control('noack');move();assert(plugin:onWeReadSyncProgress());wait(function() return not sync.pulling end)
        local dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.cancel_text==tr('Keep KOReader progress'))
        dialog.cancel_callback();UI:close(dialog);wait(function() return not sync.uploading end)
        local service=plugin.source_upload.native.service;local original=assert(service:pending())
        assert(counters[0]==2 and original.phase=='pending' and not sync.verified)
        report.unknown_retained=true
        local config=plugin.settings:get('sync');config.ask_on_conflict=false;config.upload_interval_minutes=0;plugin.settings:set('sync',config)
        move();local local_point=assert(sync:capture_local());assert(local_point.source_position.chapter_offset~=original.metadata.desired.chapter_offset)
        sync:checkpoint_local('newer_review_fixture')
        assert(plugin:onWeReadSyncProgress());dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.ok_text==tr('Check cloud position'))
        dialog.ok_callback()
        wait(function() local ctx=plugin._native_position_review_ui;return ctx and ctx.task.worker and ctx.task.worker.job end)
        local context=plugin._native_position_review_ui;local pid=context.task.worker.job.pid;pids[pid]=true;report.review_worker=true
        if kind=='cancel' then plugin.busy_message.dismiss_callback()
        elseif kind=='move' then reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
        elseif kind=='account' then
            plugin.settings:update_auth({account={user_vid='900099',name='Synthetic'},cookies={wr_vid='900099',wr_skey='synthetic-new-cookie'},api_key=''},{replace_cookies=true})
            sync:on_account_changed();require('weread.ui.native_position_review').view_changed(plugin)
            plugin.settings:update_auth({account={user_vid='900000',name='Synthetic'},cookies={wr_vid='900000',wr_skey='mock_key'},api_key=''},{replace_cookies=true})
        elseif kind=='offline' then plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline;plugin:onNetworkDisconnected() end
        if kind=='cancel' or kind=='move' or kind=='offline' or kind=='account' then
            wait(function() return not plugin._native_position_review_ui end)
            wait(function() return require('ffi/util').isSubProcessDone(pid) end)
            assert(counters[0]==2 and service:pending().id==original.id and plugin.settings:get_book(id).pending_upload_position)
            report.cancelled=true
        else
            wait(function() return context.token~=nil end)
            assert(counters[0]==2 and service:pending().phase=='pending','read-only review sent or erased a request')
            dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.ok_text==tr('Archive and compare again'))
            local library=plugin.library_db;local open=library.open
            if kind=='storage' then
                function library:open()
                    local db=assert(open(self));return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic archive commit failure') end;return db:exec(sql) end,
                        prepare=function(_self,sql) return db:prepare(sql) end,close=function() return db:close() end}
                end
            end
            control('plain');dialog.ok_callback();library.open=open
            if kind=='storage' then
                assert(service:pending().phase=='pending' and counters[0]==2 and not plugin._native_position_review_ui)
                report.storage_preserved=true
            else
                assert(not service:pending() and counters[0]==2)
                local db=assert(library:open());local raw=db:rowexec('SELECT payload FROM native_position_write_history');db:close()
                local tombstone=json.decode(raw);assert(tombstone.phase=='pending' and tombstone.id==original.id and tombstone.metadata_sha256
                    and not raw:find(original.metadata.desired.summary,1,true));report.archived_unknown=true
                wait(function() return not sync.pulling end)
                assert(plugin.settings:get_book(id).pending_upload_position.source_position.chapter_offset==local_point.source_position.chapter_offset,
                    'retiring old record erased newer movement');report.newer_local_kept=true
                dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.cancel_text==tr('Keep KOReader progress'))
                assert(counters[0]==2,'fresh comparison ignored explicit choice');report.fresh_choice=true
                if kind=='cloud' then
                    dialog.ok_callback();UI:close(dialog)
                    wait(function() return not plugin.cloud_source_request and not plugin.source_navigation.job end)
                    assert(sync.verified and not plugin.settings:get_book(id).pending_upload_position,'raw cloud choice did not finish sync state')
                    assert(plugin.source_position:current().chapter_offset==original.metadata.desired.chapter_offset and counters[0]==2)
                    report.cloud_choice=true
                else
                    local request=plugin.client.request
                    function plugin.client:request(options)
                        if options.url=='https://i.weread.qq.com/book/read' then assert(service.journal:read().id~=original.id,'archived request replayed') end
                        return request(self,options)
                    end
                    dialog.cancel_callback();UI:close(dialog);wait(function() return not sync.uploading end)
                    assert(counters[0]==3 and sync.verified and not service:pending() and not plugin.settings:get_book(id).pending_upload_position)
                    report.new_request=true
                end
            end
        end
        wait(function() return require('ffi/util').isSubProcessDone(pid) end)
        local config_end=plugin.settings:get('sync');config_end.upload_on_close=false;config_end.upload_interval_minutes=0;plugin.settings:set('sync',config_end)
        clean(reader);reader:onClose(false)
        for child in pairs(pids) do wait(function() return require('ffi/util').isSubProcessDone(child) end) end
        report.workers_reaped=true
    end)
    if not ok then report.failed_line=tonumber(type(why)=='string' and why:match('native_reader_review_case%.lua:(%d+):')) or 0 end
    assert(ok,why)
end
