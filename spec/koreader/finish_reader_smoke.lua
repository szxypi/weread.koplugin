-- Real ReaderUI + production workers/SQLite/HTTP, strictly local fixtures.
return function(reader,plugin,pump,shot,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI,Crypto=require('ui/uimanager'),require('weread.lib.crypto')
    local tr=require('weread.lib.plugin_util').tr
    local Journal=require('weread.lib.finish_change_store')
    local id=assert(plugin:detectWeReadBook());local sync=plugin.progress_sync
    local scope=assert(plugin.settings:get_auth_scope())
    local credentials=require('weread.lib.native_credentials'):new(plugin.settings);local _,revision=credentials:read()
    assert(credentials:save({vid=scope.vid,accessToken='mock-native-access',refreshToken='mock-native-refresh',
        deviceId='eink334691225'..string.rep('1',19)},scope,revision,26))
    local function request(path,data)
        local chunks,body={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=body and 'POST' or 'GET',source=body and LTN.source.string(body),sink=LTN.sink.table(chunks),
            headers=body and {['Content-Type']='application/json',['Content-Length']=tostring(#body)} or {}}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local total=0;for _i,row in ipairs(request('/__state').totals) do if row.path==path then total=total+row.count end end;return total
    end
    local function copy(value) return Json.decode(Json.encode(value)) end
    local function raw(path) local file=assert(io.open(path,'rb'));local value=file:read('*a');file:close();return value end
    local function same(left,right)
        if type(left)~=type(right) then return false end
        if type(left)~='table' then return left==right end
        for key,value in pairs(left) do if not same(value,right[key]) then return false end end
        for key in pairs(right) do if left[key]==nil then return false end end
        return true
    end
    local config=copy(plugin.settings:get('sync'));local quiet=copy(config);quiet.upload_interval_minutes=0;quiet.upload_on_close=false;quiet.ask_on_conflict=true
    plugin.settings:set('sync',quiet);plugin.settings:flush();sync.interval:halt()
    local report_config=copy(plugin.settings:get('read_report'));local off=copy(report_config);off.enabled=false
    plugin.settings:set('read_report',off);plugin.read_report:stop('finish_reader_fixture');plugin.settings:flush()
    clean_popups(reader)
    local file_path=reader.document.file;local file_hash=Crypto.sha256_hex(raw(file_path))
    local state_path=plugin.settings:get_book(id).cache_dir..'/reading_state.json'
    local journal=Journal:new(plugin.library_db,plugin.client)
    local original_request=plugin.client.request;local parent=tonumber(require('ffi').C.getpid())
    function plugin.client:request(options)
        if options.url=='https://i.weread.qq.com/book/markstatus' then
            assert(tonumber(require('ffi').C.getpid())~=parent,'finished-mark HTTP blocked the native reader')
            local record=assert(journal:read());local body=Json.decode(options.body)
            assert(record.phase=='pending' and record.metadata.book_id==id and body.bookId==id and options.method=='POST')
            assert(record.metadata.request_hash==require('weread.lib.thought_edit_contract').body_hash(body))
            assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive and not options.headers.Cookie)
            -- Counters live in the actual loopback server; no fork-local count
            -- is mistaken for the parent's authoritative request total.
        end
        return original_request(self,options)
    end
    local function row(label)
        for _i,item in ipairs(assert(plugin._shelf_state_menu).item_table) do if item.text==tr(label) then return item end end
        error('missing finished-mark native row')
    end
    local function preview(resolving)
        clean_popups(reader)
        local entry
        for _i,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Book details') then entry=item end end
        assert(entry);entry.callback();pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
        for _i,button in ipairs(plugin._book_detail_view._action_buttons) do if button.text==tr('Shelf status') then button.callback();break end end
        row(resolving and 'Check pending finished-mark change' or 'Change finished mark').callback()
        pump(function() return plugin._finish_change_ui and plugin._finish_change_ui.dialog end)
        return plugin._finish_change_ui.dialog
    end
    local function confirm(view) UI:forceRePaint();view.ok_callback();pump(function() return not plugin._finish_change_ui end) end
    local function accept()
        local before=count('/book/markstatus');local view=preview(true);view.ok_callback()
        assert(plugin._finish_change_ui and plugin._finish_change_ui.dialog~=view)
        confirm(plugin._finish_change_ui.dialog)
        assert(journal:read().phase=='idle' and count('/book/markstatus')==before,'pending reconciliation wrote to the cloud')
    end
    local function move()
        clean_popups(reader);reader.rolling:onGotoPage(reader:getCurrentPage()==1 and 2 or 1)
        pump(function() return plugin.source_position:current()~=nil end)
        assert(sync.dirty);sync:checkpoint_local('finished_mark_fixture')
        assert(plugin.settings:get_book(id).pending_upload_position)
    end
    move()
    local point=assert(plugin.source_position:current());local dom=assert(require('weread.lib.source_dom').open(reader.document,id,point.chapter_uid))
    local first=assert(dom:locate(point.chapter_offset)).xpointer;local last=assert(reader.document:getNextVisibleChar(first))
    local note={page=first,pos0=first,pos1=last,drawer='underscore',text='合成本机划线',note='读完标记测试应保留这条本机附注',datetime='2026-11-11 12:00:00'}
    reader.annotation:addItem(note);reader.annotation:onSaveSettings();reader.doc_settings:flush()
    local notes=copy(reader.annotation.annotations)
    local before_state=Json.decode(raw(state_path));local origin=reader.document:getXPointer()
    local data_before,auth_before=count('/web/book/read'),count('/login')+count('/web/login/renewal')
    local posts=count('/book/markstatus')
    local function preserved()
        assert(Crypto.sha256_hex(raw(file_path))==file_hash and reader.document:getXPointer()==origin,'finished mark moved/replaced native content')
        local current=Json.decode(raw(state_path));local changed={}
        for key,value in pairs(before_state) do if not same(current[key],value) then changed[#changed+1]=key end end
        for key in pairs(current) do if before_state[key]==nil then changed[#changed+1]=key end end
        assert(same(current,before_state) and plugin.settings:get_book(id).pending_upload_position,'finished mark replaced local sync state fields: '..table.concat(changed,','))
        assert(same(reader.annotation.annotations,notes) and same(reader.doc_settings:readSetting('annotations'),notes),'finished mark changed native annotations')
        assert(count('/web/book/read')==data_before and count('/login')+count('/web/login/renewal')==auth_before,'finished mark sent progress or renewed auth')
    end
    local view=preview();assert(view.ok_text==tr('Mark as finished'));shot('finished-reader-mark-confirmation');confirm(view)
    assert(count('/book/markstatus')==posts+1 and journal:read().phase=='idle');preserved()
    request('/__control',{finished_mark_mode='empty'});view=preview();assert(view.ok_text==tr('Mark as unfinished'));confirm(view)
    assert(count('/book/markstatus')==posts+2 and journal:read().phase=='idle');preserved()
    request('/__control',{finished_mark_mode='plain'});view=preview();view.cancel_callback()
    assert(not plugin._finish_change_ui and count('/book/markstatus')==posts+2);preserved()
    view=preview();UI:close(plugin._shelf_state_menu);view.ok_callback()
    assert(not plugin._finish_change_ui and count('/book/markstatus')==posts+2);preserved()
    view=preview();request('/__control',{progress_offset_delta=1});confirm(view)
    assert(count('/book/markstatus')==posts+2 and journal:read().phase=='idle');preserved()
    request('/__control',{progress_offset_delta=0,finished_mark_mode='position'});view=preview();confirm(view)
    assert(count('/book/markstatus')==posts+3 and journal:read().phase=='pending');preserved()
    shot('finished-reader-position-conflict');accept();preserved()
    request('/__control',{progress_offset_delta=0,finished_mark_mode='plain'})

    -- Uploads below are explicit independent progress operations. They must
    -- complete normally, while the finished-mark check notices the change
    -- instead of restoring/overwriting that newer position.
    local function finish_sync()
        pump(function()
            local choice=UI:getTopmostVisibleWidget()
            if sync.state=='awaiting_choice' and choice and choice.cancel_text==tr('Keep KOReader progress') then
                choice.cancel_callback();UI:close(choice)
            end
            return not sync.pulling and not sync.uploading and not sync.interval.cycle
        end)
        assert(sync.verified and not sync.dirty and not plugin.source_dispatch:pending(id) and not plugin.settings:get_book(id).pending_upload_position)
    end
    clean_popups(reader);assert(plugin:onWeReadSyncProgress());finish_sync()
    local timer=sync.interval;local original_now=timer.now;local clock=100
    for _i,kind in ipairs({'manual','interval'}) do
        if kind=='interval' then
            local enabled=copy(quiet);enabled.upload_interval_minutes=1;plugin.settings:set('sync',enabled)
            timer.now=function() return clock end
        end
        move();local selected=assert(plugin.source_position:current());local pointer=reader.document:getXPointer()
        local old_marks=count('/book/markstatus');local old_uploads=count('/web/book/read')
        request('/__control',{finished_mark_mode='hold'});view=preview();view.ok_callback()
        pump(function() return request('/__state').finished_held end)
        if kind=='manual' then assert(plugin:onWeReadSyncProgress())
        else
            assert(timer.task and timer.due);clock=timer.due
            UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
        end
        finish_sync()
        assert(request('/__state').finished_held,'finished-mark hold expired before concurrent synchronization')
        assert(count('/web/book/read')>old_uploads,'concurrent progress operation did not dispatch')
        local uploaded=assert(plugin.settings:get_book(id).last_uploaded_position)
        assert(uploaded.chapter_offset==selected.chapter_offset and uploaded.chapter_uid==selected.chapter_uid,'newer source coordinate was not acknowledged')
        request('/__control',{finished_mark_mode='plain'})
        pump(function() return not plugin._finish_change_ui end)
        assert(count('/book/markstatus')==old_marks+1 and journal:read().phase=='pending','concurrent change was silently confirmed or resent')
        assert(reader.document:getXPointer()==pointer and same(reader.annotation.annotations,notes),'concurrent finished mark lost native state')
        local state_before_accept=Json.decode(raw(state_path));accept()
        local state_after_accept=Json.decode(raw(state_path));local changes={}
        local function differences(left,right,path)
            if same(left,right) then return end
            if type(left)=='table' and type(right)=='table' then
                for key,value in pairs(left) do differences(value,right[key],path..'.'..tostring(key)) end
                for key in pairs(right) do if left[key]==nil then changes[#changes+1]=path..'.'..tostring(key)..'(added)' end end
            else changes[#changes+1]=path end
        end
        differences(state_before_accept,state_after_accept,'state')
        assert(same(state_after_accept,state_before_accept) and not plugin.source_dispatch:pending(id),
            'accepting finished mark replaced progress outcome: '..table.concat(changes,',')..' pending='..tostring(plugin.source_dispatch:pending(id)))
        if kind=='interval' then timer:halt();timer.now=original_now;plugin.settings:set('sync',copy(quiet)) end
    end
    clean_popups(reader)
    assert(Crypto.sha256_hex(raw(file_path))==file_hash and same(reader.annotation.annotations,notes))
    for index,item in ipairs(reader.annotation.annotations) do if item==note then table.remove(reader.annotation.annotations,index);break end end
    reader.annotation:onSaveSettings();reader.doc_settings:flush()
    plugin.client.request=original_request;plugin.settings:set('sync',config);plugin.settings:set('read_report',report_config);plugin.settings:flush()
    timer:halt();clean_popups(reader)
    local file=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/finished-reader-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,native_reader_menu=true,loopback_http=true,
        durable_intent_before_post=true,background_http=true,single_mark_unmark=true,empty_receipt_readback=true,
        cancel_and_late_confirmation_no_post=true,changed_preflight_no_post=true,position_change_retained_pending=true,
        local_checkpoint_preserved=true,native_note_preserved=true,native_file_and_location_preserved=true,
        independent_manual_sync_concurrency=true,independent_interval_sync_concurrency=true,
        newer_progress_not_overwritten=true,readonly_pending_acceptance_no_post=true,
        finished_mark_posts=count('/book/markstatus')-posts,real_account_requests_attempted=0});file:close()
end
