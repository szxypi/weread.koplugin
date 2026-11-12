-- Native timer/menu acceptance. Only the local mock service receives writes;
-- a controlled timer clock avoids spending a minute on every lifecycle case.
return function(reader,plugin,pump,shot,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI,Menu=require('ui/uimanager'),require('ui/widget/menu')
    local tr=require('weread.lib.plugin_util').tr
    local id=assert(plugin:detectWeReadBook())
    local sync,timer=plugin.progress_sync,plugin.progress_sync.interval
    assert(sync.verified and not plugin.source_dispatch:pending(id))
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local progress_menu
    for _i,item in ipairs(plugin:getSettingsMenuItems()) do if item.text==tr('Progress management') then progress_menu=item end end
    local entry=assert(progress_menu).sub_item_table_func()[3]
    assert(entry.text_func():find(tr('Off'),1,true),'timer is enabled by default')
    local items=entry.sub_item_table_func()
    assert(#items==7 and items[1].checked_func() and not items[2].checked_func())
    clean_popups(reader)
    local view=Menu:new{title=entry.text_func(),item_table=items}
    UI:show(view);shot('progress-interval-menu')
    items[2].callback(view);UI:close(view)
    assert(plugin.settings:get('sync').upload_interval_minutes==1 and not timer.task,'clean timer scheduled a request')
    local clock,original_now=100,timer.now
    timer.now=function() return clock end
    local posts,zero_posts=0,0
    local original=plugin.client.request
    function plugin.client:request(options)
        if options.url=='https://weread.qq.com/web/book/read' then
            posts=posts+1
            local body=Json.decode(options.body)
            assert(plugin.source_dispatch:pending(id),'timed HTTP dispatched before journal')
            if body.rt~=nil then
                local point=assert(plugin.source_position:current())
                assert(body.rt==0 and body.co==point.chapter_offset,'timed upload added duration or used estimated coordinates')
                zero_posts=zero_posts+1
            end
        end
        return original(self,options)
    end
    local function move()
        clean_popups(reader)
        reader.rolling:onGotoPage(reader:getCurrentPage()==1 and 2 or 1)
        pump(function() return plugin.source_position:current()~=nil end)
        assert(sync.dirty and timer.task,'changed source did not arm timer')
    end
    local function due()
        clock=assert(timer.due)
        UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
    end
    move()
    local original_due=timer.due
    clock=110;move()
    assert(timer.due==original_due,'continuous page turns postponed timed synchronization')
    clock=120;move()
    assert(timer.due==original_due,'repeated source captures postponed timed synchronization')
    local function http_count()
        local count=0
        for _i,row in ipairs(request('/__state').totals) do
            if not row.path:match('^/__') then count=count+row.count end
        end
        return count
    end
    local before=http_count()
    for _i=1,3 do UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
    assert(posts==0 and timer.task and clock<timer.due,'accelerated UI fired before timer deadline')
    assert(before==http_count(),'waiting timer made HTTP requests')
    due();pump(function() return not timer.cycle and not sync.uploading end)
    assert(zero_posts==1 and not timer.task and not sync.dirty and not plugin.source_dispatch:pending(id),
        'timed upload did not confirm and stop after one changed position')
    local successful_posts=posts
    -- A confirmed periodic report can leave the local movement dirty while
    -- the cloud already contains it. The timer must compare rather than post.
    sync.dirty=true;timer:refresh();due()
    pump(function() return not timer.cycle end)
    assert(posts==successful_posts and not timer.task and not sync.dirty,'equal cloud position was uploaded twice')

    move();due()
    pump(function() return sync.uploading and plugin.source_position.preview_worker and plugin.source_position.preview_worker.job end)
    local cancelled_pid=plugin.source_position.preview_worker.job.pid
    items[1].callback()
    pump(function() return require('ffi/util').isSubProcessDone(cancelled_pid) end)
    for _i=1,4 do UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
    assert(not timer.task and not timer.cycle and not sync.uploading and posts==successful_posts,
        'disabled preparation sent a late upload')
    assert(plugin.settings:get_book(id).pending_upload_position,'disabled timer discarded local intent')

    items[2].callback();request('/__control',{progress_offset_delta=1})
    due();pump(function() return sync.state=='awaiting_choice' end)
    assert(posts==successful_posts and not sync.verified,'timer overwrote a changed cloud position')
    local choice=assert(UI:getTopmostVisibleWidget())
    assert(choice.cancel_text==tr('Keep KOReader progress'),'changed cloud did not open the normal sync choice')
    shot('progress-interval-cloud-choice');UI:close(choice)
    request('/__control',{progress_offset_delta=0})
    assert(plugin:onWeReadSyncProgress())
    pump(function() return not sync.pulling end)
    choice=UI:getTopmostVisibleWidget()
    if choice and choice.cancel_text==tr('Keep KOReader progress') then choice.cancel_callback();UI:close(choice) end
    pump(function() return not sync.uploading end)
    assert(sync.verified and not timer.task)
    successful_posts=posts

    move();request('/__control',{progress_confirmation='noack'});due()
    pump(function() return not sync.uploading and not timer.cycle end)
    assert(zero_posts==3 and plugin.source_dispatch:pending(id) and not sync.verified,
        'unknown timed write lost its journal or retained automatic authority')
    assert(UI:getTopmostVisibleWidget().text==tr('The cloud position could not be confirmed.\nYour local position is kept. This upload will not be sent again automatically. Please sync again later to compare positions.'),
        'unknown timed write did not explain how to recover')
    local unknown_posts=posts
    clock=clock+600
    for _i=1,4 do UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
    assert(posts==unknown_posts and posts==successful_posts+1,'unknown timed write was replayed')
    request('/__control',{progress_confirmation='plain'})
    clean_popups(reader);assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
    assert(sync.verified and not plugin.source_dispatch:pending(id),'read-only comparison did not restore timer session')
    items[1].callback();timer.now=original_now;plugin.client.request=original
    assert(not timer.task and not timer.cycle and plugin.settings:get('read_report').enabled==false,
        'independent position timer changed periodic reading-time settings')
    local file=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/progress-interval-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,native_menu_verified=true,default_off=true,
        controlled_clock=true,configured_minutes=1,early_tick_no_http=true,changed_source_zero_time_upload=true,
        page_turn_recapture_preserves_deadline=true,
        equal_cloud_skips_duplicate_upload=true,
        no_idle_deadline=true,disable_cancelled_worker=true,cancelled_worker_reaped=true,
        changed_cloud_requires_choice=true,unknown_write_not_replayed=true,readonly_recheck_restored=true,
        reading_time_setting_unchanged=true,real_account_data_writes_attempted=0});file:close()
end
