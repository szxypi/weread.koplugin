-- Inject filesystem durability failures into real recovery composition; mock HTTP only.
return function(reader,plugin,pump,shot,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI,Auth,WebUI=require('ui/uimanager'),require('weread.lib.web_authorization'),require('weread.ui.web_renewal')
    local tr=require('weread.lib.plugin_util').tr
    local sync,timer=plugin.progress_sync,plugin.progress_sync.interval
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
    local original_timer_now=timer.now
    local function reset()
        clean_popups(reader)
        plugin.settings:get('sync').upload_interval_minutes=0;timer:reschedule();timer.now=original_timer_now
        request('/__control',{match='',times=0,delay=0,web_renewal_mode='plain'})
        plugin.settings:update_auth({account=plugin.settings:get('account'),
            cookies={wr_vid='900000',wr_skey='mock-save-before'},wr_ticket='',wr_wrpa=''}, {replace_cookies=true})
        plugin:onWeReadAccountChanged();sync:on_reader_ready();plugin.web_renewal=nil
        pump(function() return sync.current_book_id==id and plugin.source_position:current() end)
        assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        assert(sync.verified and not plugin.source_dispatch:pending(id));clean_popups(reader)
    end
    local function inject(stage)
        local service=WebUI.service(plugin);local store=service.store
        local original,blocked,hits=store.sync,true,0
        store.sync=function(path)
            local record=store:read()
            if blocked and (stage=='credentials' and path==plugin.settings.settings_file
                or stage=='receipt' and path==store.path and record.phase=='verified'
                or stage=='done' and path==store.path and record.phase=='done') then
                hits=hits+1;return false
            end
            return original(path)
        end
        return service,function() blocked=false;store.sync=original end,function() return hits end
    end
    local done,plan,reason
    local function start(consumer)
        done,plan,reason=false,nil,nil
        request('/__control',{match=consumer=='source' and '/api/userInfo' or '/web/book/getProgress',times=1,status=401,web_renewal_mode='rotate'})
        if consumer=='source' then
            assert(plugin.source_upload:prepare(assert(sync:capture_local()),function(value,why) plan,reason,done=value,why,true end))
        elseif consumer=='timed' then
            plugin.settings:get('sync').upload_interval_minutes=1;plugin.settings:flush()
            local clock=100;timer.now=function() return clock end
            sync.dirty=true;timer:refresh();clock=assert(timer.due)
            UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
        else assert(plugin:onWeReadSyncProgress()) end
    end
    local function dialog()
        pump(function() return plugin._web_renewal_request and plugin._web_renewal_request.dialog end)
        local view=plugin._web_renewal_request.dialog
        assert(view==UI:getTopmostVisibleWidget() and view.text==tr('Could not save the renewed login. Retry saving without another renewal request?'),
            'save failure did not show the native receipt-only retry')
        return view
    end
    local function complete(consumer)
        pump(function() return consumer=='source' and done or consumer~='source' and not sync.pulling and not timer.cycle end)
        assert(not plugin._web_renewal_request and not plugin.source_recovery.job,'completed save retry retained recovery ownership')
        if consumer=='source' then assert(plan and not reason and plan.is_current(),'source did not reprepare with the saved receipt')
        else assert(sync.verified,'progress did not recompare with the saved receipt') end
    end
    local posts_before=count('/web/book/read')
    local cases={}
    for _i,consumer in ipairs({'progress','source','timed'}) do
        for _j,stage in ipairs(consumer=='timed' and {'credentials'} or {'receipt','credentials','done'}) do
            reset()
            local service,unblock,hits=inject(stage)
            local revision=Auth.capture(plugin.settings).revision
            local origin=reader.document:getXPointer()
            local before=count('/web/login/renewal')
            start(consumer);local view=dialog()
            assert(hits()>0 and count('/web/login/renewal')==before+1 and service.job.state=='save_failed')
            assert(consumer~='source' or not done,'source resumed before durable credential save')
            assert(consumer=='source' or sync.pulling or timer.cycle,'preflight stopped waiting before the save decision')
            if consumer=='progress' and stage=='credentials' then shot('recovery-save-retry') end
            plugin.settings:set('recovery_save_fixture_preference',consumer..'/'..stage);plugin.settings:flush()
            unblock();view.ok_callback();complete(consumer)
            assert(count('/web/login/renewal')==before+1,'save-only retry repeated the renewal POST')
            assert(service.store:read().phase=='done' and not service.store:read().candidate,'completed receipt retained credentials')
            assert(Auth.capture(plugin.settings).revision~=revision,'recovered credentials were not durable in memory and primary settings')
            assert(plugin.settings:get('recovery_save_fixture_preference')==consumer..'/'..stage,'save retry overwrote fresh local settings')
            assert(reader.document:getXPointer()==origin and count('/web/book/read')==posts_before,'save retry moved the reader or sent reading data')
            view.ok_callback();assert(count('/web/login/renewal')==before+1,'late retry button repeated a completed operation')
            cases[#cases+1]={consumer=consumer,stage=stage,result='PASS',renewal_posts=1,save_only_retry=true}
        end
    end
    -- Cancel after the primary file has changed but before its durability check
    -- succeeds. A recreated service must verify the durable receipt, not POST.
    reset()
    local service,unblock=inject('credentials')
    sync.dirty=true
    local before=count('/web/login/renewal');start('progress');local view=dialog()
    assert(Auth.memory(plugin.settings).revision~=Auth.primary(plugin.settings).revision,'cancel fixture did not retain split memory/primary revisions')
    view.cancel_callback();pump(function() return not sync.pulling end)
    assert(not sync.verified and service.store:read().phase=='verified','cancel discarded a verified receipt or kept the report gate')
    assert(plugin.settings:get_book(id).pending_upload_position,'cancel discarded the local reading intent')
    unblock();plugin.web_renewal=nil
    local _,primary=Auth.primary(plugin.settings)
    local altered=Json.decode(Json.encode(primary));altered.cookies.wr_skey='mock-unrecognized-primary'
    local settings_file=require('luasettings'):open(plugin.settings.settings_file);settings_file.data=altered;settings_file:flush()
    local foreign_revision=Auth.primary(plugin.settings).revision
    request('/__control',{match='/web/book/getProgress',times=1,status=401,web_renewal_mode='rotate'})
    clean_popups(reader);assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
    assert(not sync.verified and count('/web/login/renewal')==before+1 and service.store:read().phase=='verified'
        and Auth.primary(plugin.settings).revision==foreign_revision,'unrecognized primary was adopted, overwritten or renewed')
    settings_file=require('luasettings'):open(plugin.settings.settings_file);settings_file.data=primary;settings_file:flush()
    plugin.web_renewal=nil;request('/__control',{match='/web/book/getProgress',times=1,status=401,web_renewal_mode='rotate'})
    clean_popups(reader);assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
    assert(sync.verified and count('/web/login/renewal')==before+1,'recreated consumer could not resume the verified receipt without POST')
    for _i,mode in ipairs({'page','timer_off','deadline'}) do
        reset();service,unblock=inject('credentials')
        local origin=reader:getCurrentPage()
        local original_now=sync.now;local clock=100
        if mode=='deadline' then sync.now=function() return clock end end
        before=count('/web/login/renewal');start(mode=='timer_off' and 'timed' or 'progress');view=dialog()
        if mode=='page' then reader.rolling:onGotoPage(origin==1 and 2 or 1)
        elseif mode=='timer_off' then plugin.settings:get('sync').upload_interval_minutes=0;timer:reschedule()
        else clock=136;sync.pull_job.recovery_timeout() end
        assert(not plugin._web_renewal_request and not plugin.source_recovery.job and not sync.pulling and not timer.cycle,
            'save prompt retained an invalid consumer: '..mode)
        assert(service.store:read().phase=='verified','cancelled consumer discarded its verified receipt: '..mode)
        view.ok_callback();view.cancel_callback()
        assert(count('/web/login/renewal')==before+1 and count('/web/book/read')==posts_before,'late save decision dispatched HTTP: '..mode)
        unblock();sync.now=original_now
        if mode=='page' then reader.rolling:onGotoPage(origin);pump(function() return plugin.source_position:current() end) end
    end
    reset()
    assert(count('/web/book/read')==posts_before,'combined retry cases sent reading data')
    local output=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/recovery-save-retry-result.json','wb'))
    output:write(Json.encode{result='PASS',synthetic_only=true,cases=cases,native_dialog_verified=true,
        latest_preferences_preserved=true,native_location_preserved=true,completed_receipt_credentials_removed=true,
        cancelled_verified_receipt_retained=true,recreated_consumer_resumes_without_post=true,
        unrecognized_primary_no_adoption_or_post=true,cancel_preserves_local_intent=true,
        native_page_turn_cancels_save_prompt=true,timer_off_cancels_save_prompt=true,deadline_cancels_save_prompt=true,late_save_decisions_no_http=true,
        mock_reading_posts=0,real_account_requests_attempted=0});output:close()
end
