-- Native progress preflight, parent renewal, cancellation and rereads; mock only.
return function(reader,plugin,pump,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI=require('ui/uimanager')
    local id=assert(plugin:detectWeReadBook())
    local sync,timer=plugin.progress_sync,plugin.progress_sync.interval
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local total=0
        for _i,row in ipairs(request('/__state').totals) do
            if (row.api~='' and row.api or row.path)==path then total=total+row.count end
        end
        return total
    end
    local data_before=count('/web/book/read')
    local key=plugin.settings:get('api_key')
    local function compare()
        clean_popups(reader);assert(plugin:onWeReadSyncProgress())
        pump(function() return not sync.pulling end)
    end
    local function fresh_login()
        request('/__control',{match='',times=0,delay=0,web_renewal_mode='plain'})
        plugin.settings:update_auth({account=plugin.settings:get('account')})
        plugin:onWeReadAccountChanged();sync:on_reader_ready()
        pump(function() return sync.current_book_id==id and plugin.source_position:current() end)
        compare();assert(sync.verified,'fresh mock login did not restore the reading session')
        clean_popups(reader)
    end
    local function fail_once(times,status)
        request('/__control',{match='/web/book/getProgress',times=times or 1,status=status or 401,web_renewal_mode='rotate'})
    end
    clean_popups(reader)
    local before,web_before,gateway_before=count('/web/login/renewal'),count('/web/book/getProgress'),count('/book/getprogress')
    fail_once();assert(plugin:onWeReadSyncProgress())
    pump(function() return plugin.web_renewal and plugin.web_renewal.worker and plugin.web_renewal.worker.job end)
    assert(sync.pulling and not sync.verified,'Web 401 accepted the other channel before renewal')
    pump(function() return not sync.pulling end)
    assert(sync.verified and count('/web/login/renewal')==before+1,'manual preflight did not recover exactly once')
    assert(count('/web/book/getProgress')==web_before+2 and count('/book/getprogress')==gateway_before+2,
        'recovery did not reread both progress sources')

    plugin.settings:set('api_key','');plugin.settings:flush()
    before=count('/web/login/renewal');fail_once();compare()
    assert(sync.verified and count('/web/login/renewal')==before+1,'Web-only preflight recovery failed')
    for _i,status in ipairs({403,429}) do
        before=count('/web/login/renewal');fail_once(1,status);compare()
        assert(not sync.verified and count('/web/login/renewal')==before,'non-401 progress response renewed login')
    end
    before=count('/web/login/renewal');fail_once(2);compare()
    assert(not sync.verified and sync.state=='error' and count('/web/login/renewal')==before+1,
        'second progress 401 renewed twice or retained the report gate')
    assert(not sync:position_for_report(id),'failed preflight allowed automatic reporting')
    plugin.settings:set('api_key',key);plugin.settings:flush();fresh_login()

    -- A normal opening pull uses the same preflight, without choosing a cloud
    -- position or sending an account-data write during credential recovery.
    local config=plugin.settings:get('sync')
    local opening=config.pull_on_open;config.pull_on_open=true;plugin.settings:flush()
    before=count('/web/login/renewal');fail_once();sync:on_reader_ready()
    pump(function() return sync.current_book_id==id and not sync.pulling and sync.verified end)
    assert(count('/web/login/renewal')==before+1,'opening pull did not recover')
    config.pull_on_open=opening;plugin.settings:flush()
    pump(function() return plugin.source_position:current() end)

    local plan,done
    assert(plugin.source_upload:prepare(assert(sync:capture_local()),function(value) plan,done=value,true end))
    pump(function() return done end)
    assert(plan,'could not prepare the bounded pending-dispatch fixture')
    local uncertain=assert(plugin.source_dispatch:begin(id,plan.position,plan.source_position,'position'))
    before=count('/web/login/renewal');fail_once();compare()
    assert(not sync.verified and plugin.source_dispatch:owns(uncertain) and count('/web/login/renewal')==before,
        'pending dispatch was discarded or allowed preflight renewal')
    request('/__control',{match='',times=0});compare()
    assert(sync.verified and not plugin.source_dispatch:pending(id),'readonly comparison did not resolve the pending dispatch')

    before=count('/web/login/renewal')
    request('/__control',{match='/web/book/getProgress',times=1,status=401,web_renewal_mode='empty'})
    compare()
    assert(not sync.verified and count('/web/login/renewal')==before+1,'unconfirmed preflight renewal was accepted')
    assert(plugin.web_renewal.store:read().phase=='pending','unconfirmed renewal intent was lost')
    assert(not plugin.web_renewal.job);plugin.web_renewal=nil
    fail_once();compare()
    assert(not sync.verified and count('/web/login/renewal')==before+1,'recreated preflight renewal service replayed the POST')
    fresh_login()

    fail_once();assert(plugin:onWeReadSyncProgress())
    pump(function() return plugin.web_renewal and plugin.web_renewal.worker and plugin.web_renewal.worker.job end)
    local cancelled_pid=plugin.web_renewal.worker.job.pid
    local origin=reader:getCurrentPage()
    local reads_before=count('/web/book/getProgress')
    reader.rolling:onGotoPage(origin==1 and 2 or 1)
    pump(function() return require('ffi/util').isSubProcessDone(cancelled_pid) end)
    assert(not sync.pulling and not sync.pull_job and not plugin.source_recovery.job,'native page turn retained the old preflight')
    assert(count('/web/book/getProgress')==reads_before,'cancelled preflight performed late progress reads')
    reader.rolling:onGotoPage(origin);pump(function() return plugin.source_position:current() end)
    fresh_login()

    local original_now=timer.now
    local clock=100;timer.now=function() return clock end
    config=plugin.settings:get('sync');config.upload_interval_minutes=1;plugin.settings:flush()
    sync.dirty=true;timer:refresh();assert(timer.task)
    before=count('/web/login/renewal');fail_once();clock=assert(timer.due)
    UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
    pump(function() return not timer.cycle end)
    assert(sync.verified and not sync.dirty and count('/web/login/renewal')==before+1,'timed preflight failed to recover and compare')
    config.upload_interval_minutes=0;timer:reschedule();timer.now=original_now;plugin.settings:flush()
    assert(count('/web/book/read')==data_before,'progress recovery-only cases sent reading data')
    clean_popups(reader)
    local file=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/progress-fetch-recovery-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,manual_401_one_parent_renewal=true,
        both_progress_sources_reread=true,web_only_recovery=true,opening_pull_recovery=true,timed_preflight_recovery=true,
        second401_stops_report_gate=true,non401_no_renewal=true,pending_dispatch_blocks_renewal=true,
        readonly_pending_resolution=true,unknown_auth_receipt_retained=true,fresh_service_no_replay=true,
        native_page_turn_cancels_recovery=true,cancelled_worker_reaped=true,no_late_progress_reads=true,
        mock_reading_posts_during_preflight=0,real_account_requests_attempted=0});file:close()
end
