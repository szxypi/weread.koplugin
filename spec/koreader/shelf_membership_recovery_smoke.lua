-- Real workers, durable credentials and native dialogs; mock service only.
return function(reader,plugin,pump,clean_popups,helpers)
    local request,count,writes,preview,confirm,present=helpers.request,helpers.count,helpers.writes,
        helpers.preview,helpers.confirm,helpers.present
    local UI=require('ui/uimanager')
    local store=require('weread.lib.native_credentials'):new(plugin.settings)
    local function native_revision() local _,revision=store:read();return revision end
    local function auths() return count('/login') end
    local function start(resolve)
        clean_popups(reader);assert(plugin:showShelfState(helpers.id))
        local label=require('weread.lib.plugin_util').tr(resolve and 'Check pending bookshelf change' or 'Change cloud membership')
        for _i,item in ipairs(plugin._shelf_state_menu.item_table) do
            if item.text==label then item.callback();return end
        end
        error('missing membership recovery entry')
    end
    local data,auth,revision=writes(),auths(),native_revision()
    request('/__control',{match='/shelf/sync',times=1,skip=0,status=401})
    local view=preview()
    local _,next_revision,_,pending=store:read()
    assert(next_revision==revision+2 and not pending and auths()==auth+1 and writes()==data,
        'preview401 did not renew once and return to an unsent confirmation')
    view.cancel_callback();assert(not plugin._shelf_membership_ui and not plugin.shelf_membership:pending())

    auth,revision=auths(),native_revision();view=preview();local previous=view
    request('/__control',{match='/shelf/sync',times=1,skip=0,status=401})
    view.ok_callback()
    pump(function() return plugin._shelf_membership_ui and plugin._shelf_membership_ui.dialog end)
    view=plugin._shelf_membership_ui.dialog
    assert(view~=previous and auths()==auth+1 and native_revision()==revision+2 and writes()==data
        and not plugin.shelf_membership:pending(),'preflight renewal reused confirmation or retained proven-unsent intent')
    previous.ok_callback();assert(writes()==data and not plugin.shelf_membership.job,'old button survived renewal')
    confirm(view);present(helpers.id,false)
    assert(writes()==data+1 and auths()==auth+1,'new confirmation did not issue exactly one membership change')
    view=preview();confirm(view);present(helpers.id,true)

    data,auth=writes(),auths()
    request('/__control',{match='/shelf/delete',times=1,skip=0,status=401})
    view=preview();confirm(view)
    assert(writes()==data+1 and auths()==auth and plugin.shelf_membership:pending(),'write401 renewed or lost its uncertain intent')
    request('/__control',{match='/shelf/sync',times=1,skip=0,status=401})
    start(true);pump(function() return not plugin._shelf_membership_ui end)
    assert(auths()==auth and writes()==data+1 and plugin.shelf_membership:pending(),'pending readonly resolution silently renewed')
    view=preview(nil,true);confirm(view);present(helpers.id,true)

    data,auth=writes(),auths();view=preview()
    request('/__control',{match='/shelf/sync',times=3,skip=1,status=401})
    confirm(view)
    assert(writes()==data+1 and auths()==auth and plugin.shelf_membership:pending(),'post-write401 retried a possible dispatch')
    view=preview(nil,true);confirm(view);present(helpers.id,false)
    view=preview();confirm(view);present(helpers.id,true)

    -- Delay both the first401 and the subsequent login. Closing the actual
    -- status window must reap the owned worker and retain uncertain renewal.
    data,auth,revision=writes(),auths(),native_revision()
    request('/__control',{match='',times=1,skip=0,status=401,delay=.4})
    start()
    pump(function() return (request('/__state').active_requests['https://i.weread.qq.com/login'] or 0)>0 end)
    local pid=assert(plugin.native_renewal.worker.job).pid
    UI:close(assert(plugin._shelf_state_menu))
    pump(function() return require('ffi/util').isSubProcessDone(pid)
        and (request('/__state').active_requests['https://i.weread.qq.com/login'] or 0)==0 end)
    request('/__control',{match='',times=0,skip=0,delay=0})
    local credentials,held_revision,_,held=store:read()
    assert(held and held_revision==revision+1 and not plugin.native_renewal.job
        and not plugin._shelf_membership_ui and writes()==data and auths()==auth+1,
        'closed status window lost auth uncertainty or failed to reap the worker')
    start();assert(not plugin._shelf_membership_ui and not plugin.native_renewal.job and auths()==auth+1,
        'fresh membership entry replayed an uncertain authentication POST')
    -- Explicitly reset only this synthetic fixture; production retains the
    -- pending receipt until the owner resolves it in authentication settings.
    assert(store:save(credentials,plugin.settings:get_auth_scope(),held_revision,26))
    view=preview();view.cancel_callback()
    return {preview401_once_new_confirmation=true,preflight401_unsent_journal_finished=true,
        preflight401_new_confirmation_required=true,stale_button_no_post=true,
        write401_no_renewal_or_repost=true,postwrite401_no_renewal_or_repost=true,
        pending_resolution401_no_renewal=true,status_close_auth_worker_reaped=true,
        unknown_auth_receipt_retained_no_replay=true,real_account_requests_attempted=0}
end
