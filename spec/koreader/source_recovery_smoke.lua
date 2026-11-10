-- Real native preparation, renewal store, pipe workers and HTTP; mock only.
return function(reader,plugin,pump,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local id=assert(plugin:detectWeReadBook())
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local total=0
        for _i,row in ipairs(request('/__state').totals) do if row.path==path then total=total+row.count end end
        return total
    end
    local data_before=count('/web/book/read')
    local source_workers,renewal_observed={},false
    local function observe()
        local job=plugin.source_position.preview_worker and plugin.source_position.preview_worker.job
        if job then source_workers[job.pid]=true end
        if plugin.web_renewal and plugin.web_renewal.worker and plugin.web_renewal.worker.job then renewal_observed=true end
    end
    local plan,reason,done
    local function begin()
        plan,reason,done=nil,nil,false
        local position=assert(plugin.progress_sync:capture_local())
        assert(plugin.source_upload:prepare(position,function(value,why) plan,reason,done=value,why,true end))
    end
    local function complete()
        pump(function() observe();return done end)
    end
    clean_popups(reader)
    local before=count('/web/login/renewal')
    request('/__control',{match='/api/userInfo',times=1,status=401,web_renewal_mode='rotate'})
    begin();complete()
    assert(plan and plan.is_current() and plan.position.chapter_offset==plugin.source_position:current().chapter_offset,
        'verified recovery did not produce a new current source plan')
    assert(count('/web/login/renewal')==before+1 and count('/web/book/read')==data_before,'source recovery renewed twice or wrote progress')
    local worker_count=0;for _pid in pairs(source_workers) do worker_count=worker_count+1 end
    assert(worker_count>=4 and renewal_observed,'source archives and currentness were not freshly prepared around parent renewal')
    local uncertain=assert(plugin.source_dispatch:begin(id,plan.position,plan.source_position,'position'))
    before=count('/web/login/renewal')
    request('/__control',{match='/web/book/chapter/e_0',times=1,status=401})
    begin();complete()
    assert(not plan and plugin.source_dispatch:owns(uncertain) and count('/web/login/renewal')==before,
        'uncertain reading dispatch allowed auth recovery or lost its record')
    request('/__control',{match='',times=0})
    clean_popups(reader);assert(plugin:onWeReadSyncProgress());pump(function() return not plugin.progress_sync.pulling end)
    assert(plugin.progress_sync.verified and not plugin.source_dispatch:pending(id),'readonly comparison did not resolve reserved dispatch')
    clean_popups(reader)
    for _i,status in ipairs({403,429}) do
        before=count('/web/login/renewal')
        request('/__control',{match='/api/userInfo',times=1,status=status})
        begin();complete()
        assert(not plan and reason=='source_currentness_unavailable' and count('/web/login/renewal')==before,'non-401 renewed login')
    end
    before=count('/web/login/renewal')
    request('/__control',{match='/web/book/chapter/e_0',times=2,status=401})
    begin();complete()
    assert(not plan and reason=='source_authentication_unavailable' and count('/web/login/renewal')==before+1,
        'second HTTP 401 repeated credential maintenance')
    assert(not plugin.progress_sync.verified and not plugin.progress_sync:position_for_report(id),'failed recovery retained automatic report gate')

    -- A fresh same-owner mock login changes the epoch. Keep old bounded
    -- receipts on disk; they cannot block or authorize the new login.
    local function fresh_login()
        request('/__control',{match='',times=0,delay=0,web_renewal_mode='plain'})
        plugin.settings:update_auth({account=plugin.settings:get('account')})
        plugin:onWeReadAccountChanged();plugin.progress_sync:on_reader_ready()
        pump(function() return plugin.progress_sync.current_book_id==id and plugin.source_position:current() end)
        clean_popups(reader);assert(plugin:onWeReadSyncProgress())
        pump(function() return not plugin.progress_sync.pulling end)
        assert(plugin.progress_sync.verified,'fresh mock login could not compare the preserved position')
        clean_popups(reader)
    end
    fresh_login()
    before=count('/web/login/renewal')
    request('/__control',{match='/web/book/chapter/e_0',times=1,status=401,web_renewal_mode='empty'})
    begin();complete()
    assert(not plan and count('/web/login/renewal')==before+1,'unconfirmed maintenance response was accepted or retried')
    local record=assert(plugin.web_renewal.store:read());assert(record.phase=='pending','unconfirmed auth intent was discarded')
    assert(not plugin.web_renewal.job);plugin.web_renewal=nil
    request('/__control',{match='/web/book/chapter/e_0',times=1,status=401,web_renewal_mode='rotate'})
    begin();complete()
    assert(not plan and count('/web/login/renewal')==before+1,'fresh renewal service replayed an uncertain auth intent')
    fresh_login()
    request('/__control',{match='/web/book/chapter/e_0',times=1,status=401})
    begin()
    pump(function() observe();return plugin.web_renewal and plugin.web_renewal.worker and plugin.web_renewal.worker.job end)
    local cancelled_pid=plugin.web_renewal.worker.job.pid
    local origin_page=reader:getCurrentPage()
    reader.rolling:onGotoPage(origin_page==1 and 2 or 1)
    pump(function() return require('ffi/util').isSubProcessDone(cancelled_pid) end)
    assert(done and not plan and not plugin.source_recovery.job and not plugin.source_upload.job,'cancelled recovery retained its consumer')
    reader.rolling:onGotoPage(origin_page)
    pump(function() return plugin.source_position:current()~=nil end)
    fresh_login()
    assert(count('/web/book/read')==data_before,'preparation-only auth tests modified reading position')
    local file=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/source-recovery-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,confirmed_401_one_parent_renewal=true,
        independent_archive_and_source_reprepared=true,source_worker_count=worker_count,renewal_worker_observed=true,
        non401_no_renewal=true,second401_stops_auto_gate=true,unconfirmed_receipt_retained=true,
        pending_reading_dispatch_blocks_renewal=true,
        fresh_service_no_replay=true,cancelled_worker_reaped=true,fresh_same_owner_login_recompares=true,
        native_page_turn_cancelled_recovery=true,
        mock_reading_posts_during_preparation=0,real_account_data_writes_attempted=0,real_authentication_posts_attempted=0});file:close()
end
