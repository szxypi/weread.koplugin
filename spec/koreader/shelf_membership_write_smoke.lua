-- Actual native menus, child HTTP, durable journal and SQLite; synthetic only.
return function(reader,plugin,pump,shot,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI,Crypto=require('ui/uimanager'),require('weread.lib.crypto')
    local tr=require('weread.lib.plugin_util').tr
    local Credentials=require('weread.lib.native_credentials')
    local Service=require('weread.lib.shelf_membership_service')
    local id=assert(plugin:detectWeReadBook())
    local scope=assert(plugin.settings:get_auth_scope())
    local store=Credentials:new(plugin.settings);local _,revision=store:read()
    assert(store:save({vid=scope.vid,accessToken='mock-native-access',refreshToken='mock-native-refresh',
        deviceId='eink334691225'..string.rep('1',19)},scope,revision,26))
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local n=0;for _i,row in ipairs(request('/__state').totals) do if row.path==path then n=n+row.count end end;return n
    end
    local function writes() return count('/shelf/add')+count('/shelf/delete') end
    local function raw(path) local file=assert(io.open(path,'rb'));local value=file:read('*a');file:close();return value end
    local path=reader.document.file
    local state_path=assert(plugin.settings:get_book(id).cache_dir)..'/reading_state.json'
    local file_hash=Crypto.sha256_hex(raw(path))
    local origin=reader.document:getXPointer()
    local data_before,auth_before=count('/web/book/read'),count('/login')+count('/web/login/renewal')
    local parent=tonumber(require('ffi').C.getpid())
    local original_request=plugin.client.request
    function plugin.client:request(options)
        if options.url=='https://i.weread.qq.com/shelf/add' or options.url=='https://i.weread.qq.com/shelf/delete' then
            assert(tonumber(require('ffi').C.getpid())~=parent,'membership HTTP blocked the native UI')
            local pending=assert(plugin.shelf_membership:pending())
            local body=Json.decode(options.body)
            assert(#body.bookIds==1 and body.bookIds[1]==pending.book_id and options.method=='POST','wrong confirmed single-book body')
            assert(options.skip_cookie and options.persist_response_cookies==false and not options.headers.Cookie,'membership changed Web cookies')
        end
        return original_request(self,options)
    end
    local function row(label)
        for _i,item in ipairs(assert(plugin._shelf_state_menu).item_table) do if item.text==tr(label) then return item end end
        error('missing native membership action: '..label)
    end
    local function status(target)
        clean_popups(reader);assert(plugin:showShelfState(target or id))
        return plugin._shelf_state_menu
    end
    local function preview(target,resolving)
        status(target);row(resolving and 'Check pending bookshelf change' or 'Change cloud membership').callback()
        pump(function() return plugin._shelf_membership_ui and plugin._shelf_membership_ui.dialog end)
        return plugin._shelf_membership_ui.dialog
    end
    local function confirm(view)
        view.ok_callback();pump(function() return not plugin._shelf_membership_ui end)
    end
    local function present(target,value) assert(plugin.library_db:getShelfStatus(target or id).present==value,'saved membership differs from native readback') end
    local before=writes();local view=preview()
    assert(view.ok_text==tr('Remove from cloud bookshelf') and writes()==before,'preview inferred stale membership or posted')
    shot('shelf-membership-remove-confirmation');confirm(view)
    assert(writes()==before+1 and not plugin.shelf_membership:pending());present(id,false)
    clean_popups(reader);shot('shelf-membership-removed')
    view=preview();assert(view.ok_text==tr('Add to cloud bookshelf'));shot('shelf-membership-add-confirmation');confirm(view)
    present(id,true);assert(writes()==before+2)

    before=writes();view=preview();view.cancel_callback()
    assert(not plugin._shelf_membership_ui and writes()==before and not plugin.shelf_membership:pending(),'declined preview sent or reserved a write')
    view=preview();UI:close(assert(plugin._shelf_state_menu));view.ok_callback()
    assert(not plugin._shelf_membership_ui and not plugin.shelf_membership.preview and writes()==before,'closing the status window retained its confirmation')
    for _i,event in ipairs({'close','suspend','account'}) do
        view=preview()
        if event=='close' then plugin:closeWeReadUI()
        elseif event=='suspend' then plugin:onSuspend();plugin:onResume()
        else plugin:onWeReadAccountChanged() end
        view.ok_callback()
        assert(not plugin._shelf_membership_ui and not plugin.shelf_membership.job and writes()==before,'late confirmation survived '..event)
        if event~='close' then
            plugin.progress_sync:on_reader_ready();pump(function() return plugin.source_position:current() and plugin.progress_sync.current_book_id==id end)
            clean_popups(reader);assert(plugin:onWeReadSyncProgress());pump(function() return not plugin.progress_sync.pulling end)
            assert(plugin.progress_sync.verified)
        end
    end
    -- Suspend and explicit sync intentionally checkpoint the current position.
    -- Compare subsequent membership-only operations against that fresh state.
    local state_bytes=raw(state_path)

    request('/__control',{shelf_membership_mode='noack'})
    view=preview();confirm(view)
    assert(writes()==before+1 and plugin.shelf_membership:pending(),'unknown receipt lost its durable intent')
    clean_popups(reader);shot('shelf-membership-unconfirmed')
    plugin.shelf_membership:cancel();plugin.shelf_membership=Service:new{settings=plugin.settings,client=plugin.client,scheduler=UI}
    local accepted,why=plugin.shelf_membership:prepare(id,function() return true end,function() error('pending write replayed') end)
    assert(not accepted and why=='pending' and writes()==before+1,'new service replayed uncertain membership')
    request('/__control',{shelf_membership_mode='plain'})
    view=preview(nil,true);assert(view.ok_text==tr('Accept current shelf state'));shot('shelf-membership-pending-check');confirm(view)
    assert(not plugin.shelf_membership:pending() and writes()==before+1);present(id,false)
    view=preview();confirm(view);present(id,true)

    before=writes();view=preview();confirm(view);present(id,false)
    view=preview();request('/__control',{empty_shelf=true});confirm(view)
    assert(writes()==before+1 and not plugin.shelf_membership:pending(),'changed full preflight sent an add')
    request('/__control',{empty_shelf=false});view=preview();confirm(view);present(id,true)

    before=writes();request('/__control',{match='/shelf/delete',times=1,status=429})
    view=preview();confirm(view)
    assert(plugin.shelf_membership:pending() and writes()==before+1,'HTTP rejection renewed/replayed or lost intent')
    view=preview(nil,true);confirm(view);present(id,true)
    assert(writes()==before+1 and not plugin.shelf_membership:pending(),'readonly rejected-write resolution resent data')

    before=writes();request('/__control',{match='/shelf/delete',times=0,delay=.4})
    view=preview();view.ok_callback()
    pump(function() return (request('/__state').active_requests['https://i.weread.qq.com/shelf/delete'] or 0)>0 end)
    local pid=assert(plugin.shelf_membership.worker.job).pid
    assert(plugin.busy_message);plugin.busy_message:onAnyKeyPressed()
    pump(function() return require('ffi/util').isSubProcessDone(pid) and (request('/__state').active_requests['https://i.weread.qq.com/shelf/delete'] or 0)==0 end)
    request('/__control',{match='',times=0,delay=0})
    assert(plugin.shelf_membership:pending() and not plugin.shelf_membership.job,'cancelled possible dispatch was forgotten')
    view=preview(nil,true);confirm(view);present(id,false)
    assert(writes()==before+1,'cancelled write was automatically replayed')
    view=preview();confirm(view);present(id,true)

    local db=assert(plugin.library_db:open())
    db:execsql([[CREATE TRIGGER reject_membership_cache BEFORE INSERT ON shelf_state
        WHEN NEW.name='membership_snapshot' BEGIN SELECT RAISE(ABORT,'synthetic save failure'); END]])
    db:close()
    before=writes();view=preview();confirm(view)
    assert(writes()==before+1 and not plugin.shelf_membership:pending(),'confirmed cloud change was repeated after local save failure')
    present(id,true)
    db=assert(plugin.library_db:open());db:execsql('DROP TRIGGER reject_membership_cache');db:close()
    status();row('Refresh shelf status').callback()
    pump(function() return plugin._shelf_state_menu and not plugin.shelf_refreshing end);present(id,false)
    view=preview();confirm(view);present(id,true)

    local absent='900099';assert(plugin.library_db:putBook({bookId=absent,title='合成待加入书籍'}))
    before=writes();view=preview(absent);assert(view.text:find('合成待加入书籍',1,true));confirm(view);present(absent,true)
    view=preview(absent);confirm(view);present(absent,false);assert(writes()==before+2)
    assert(Crypto.sha256_hex(raw(path))==file_hash and raw(state_path)==state_bytes and reader.document:getXPointer()==origin,
        'membership changes replaced cached content, checkpoint or native position')
    assert(count('/web/book/read')==data_before and count('/login')+count('/web/login/renewal')==auth_before,
        'membership operations reported progress or renewed authentication')
    local recovery=dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'shelf_membership_recovery_smoke.lua')(
        reader,plugin,pump,clean_popups,{request=request,count=count,writes=writes,preview=preview,confirm=confirm,present=present,id=id})
    assert(Crypto.sha256_hex(raw(path))==file_hash and raw(state_path)==state_bytes and reader.document:getXPointer()==origin
        and count('/web/book/read')==data_before,'membership recovery replaced reading state or reported progress')
    plugin.client.request=original_request;clean_popups(reader)
    local output=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/shelf-membership-write-result.json','wb'))
    output:write(Json.encode{result='PASS',synthetic_only=true,native_confirmations=true,worker_http=true,durable_intent_before_http=true,
        single_book_remove_add_readback=true,absent_book_add_remove=true,preview_cancel_no_post=true,lifecycle_late_confirmation_cancelled=true,
        status_window_close_cancels_confirmation=true,
        unknown_receipt_retained=true,fresh_service_no_replay=true,explicit_readonly_pending_resolution=true,
        changed_full_preflight_no_post=true,http429_no_retry_or_renewal=true,possible_dispatch_cancel_reaped=true,
        confirmed_cloud_local_cache_failure_no_repost=true,cache_checkpoint_and_native_location_preserved=true,
        progress_and_authentication_posts_during_original_cases=0,recovery=recovery,real_account_requests_attempted=0});output:close()
end
