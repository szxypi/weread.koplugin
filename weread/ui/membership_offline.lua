-- Offline bookshelf membership requests are account-scoped and never replayed
-- after a possibly dispatched write.
local UI=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _=Util.tr
local M={}
local function queue(host)
    if not host._membership_offline_queue then
        host._membership_offline_queue=require('weread.lib.membership_queue_store'):new(host.library_db)
    end
    return host._membership_offline_queue
end
function M.get(host,id)
    if not host.library_db or not host.library_db.open then return nil end
    return queue(host):get(id)
end
local function scope(host)
    return {account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,session=host._reader_session_gen,
        document=host.ui and host.ui.document,parent=host._book_detail_view,menu=host._shelf_state_menu}
end
local function current(host,owner)
    return owner.account and owner.account==host.library_db:accountKey() and owner.epoch==(host.discovery_epoch or 0)
        and owner.session==host._reader_session_gen and owner.document==(host.ui and host.ui.document)
        and owner.parent==host._book_detail_view and owner.menu==host._shelf_state_menu
end
function M.cancel_dialog(host)
    local dialog=host._membership_offline_dialog;host._membership_offline_dialog=nil
    if dialog then UI:close(dialog) end
end
function M.cancel_sync(host)
    if host._membership_offline_sync then host._membership_offline_sync:cancel() end
    host._membership_offline_sync=nil;host._membership_offline_account=nil
end
local function allowed(host,account)
    if not account or host.library_db:accountKey()~=account or not host:isNetworkConnected()
        or host._finish_change_ui or host._shelf_flag_change_ui or host._shelf_membership_ui
        or host._finish_offline_dialog or host._membership_offline_dialog then return false end
    if host._finish_offline_sync and host._finish_offline_sync.job then return false end
    local a,ae=require('weread.ui.finish_change').pending(host)
    local b,be=require('weread.ui.shelf_flag_change').pending(host)
    return not (a or ae or b or be)
end
function M.pump(host)
    if not host.library_db or not host.library_db.open or not host.client or not host.shelf_membership then return false end
    local account=host.library_db:accountKey()
    if host._membership_offline_sync and host._membership_offline_account~=account then M.cancel_sync(host) end
    if not allowed(host,account) then return false end
    if not host._membership_offline_sync then
        host._membership_offline_account=account
        host._membership_offline_sync=require('weread.lib.membership_queue_sync'):new{
            queue=queue(host),service=host.shelf_membership,allowed=function() return allowed(host,account) end,
            cache=function(snapshot)
                if type(snapshot)~='table' then return false end
                local ok,saved=pcall(host.library_db.cacheShelf,host.library_db,snapshot.books,snapshot.archive)
                if not ok or not saved then return false end
                host:applyShelfSnapshot(snapshot.books,snapshot.archive)
                local view=host.shelf_view
                if view and view._shelf_snapshot_redraw and not host._book_detail_view and not host._shelf_state_menu then
                    UI:nextTick(function()
                        if host.library_db:accountKey()==account and host.shelf_view==view and not view._shelf_closed
                            and not host._book_detail_view and not host._shelf_state_menu then
                            view._shelf_snapshot_redraw()
                        end
                    end)
                end
                return true
            end,
            notify=function(phase)
                if host._membership_offline_account~=account then return end
                if phase=='confirmed' then
                    if host.showTransientInfo then host:showTransientInfo(_('Offline bookshelf change synced.'),3) end
                    UI:nextTick(function()
                        if host._membership_offline_account==account then
                            require('weread.ui.finish_offline').pump(host)
                            M.pump(host)
                        end
                    end)
                elseif phase=='unconfirmed' and host.showTransientInfo then
                    host:showTransientInfo(_('An offline bookshelf change needs review. It will not be sent again.'),5)
                elseif phase=='login' and host.showTransientInfo then
                    host:showTransientInfo(_('Offline bookshelf change needs E-Ink authorization. Renew it, then refresh the bookshelf.'),5)
                elseif host.showTransientInfo then
                    host:showTransientInfo(_('Offline bookshelf change could not sync. Refresh the bookshelf to try again.'),5)
                end
            end,
        }
    end
    return host._membership_offline_sync:pump()
end
function M.open(host,id)
    local owner=scope(host)
    if not current(host,owner) then return false end
    local pending,reason=queue(host):get(id)
    if reason then host:showInfo(_('Could not read offline bookshelf changes.'));return false end
    local ok,snapshot=pcall(host.library_db.getShelfStatus,host.library_db,id)
    local before
    if ok and type(snapshot)=='table' then before=snapshot.present end
    if not pending and type(before)~='boolean' then
        host:showInfo(_('The saved bookshelf has no complete membership list. Refresh it online first.'));return false
    end
    local text,label
    if pending then
        if pending.phase=='dispatching' then
            local active,err=host.shelf_membership:pending()
            if active or err then host:showInfo(_('This offline change may have been sent. Check the pending bookshelf change first.'));return false end
            text=_('This offline change may have been sent. Remove its local record without retrying? Check the current cloud status separately; a delayed change may still appear.')
        else text=_('Cancel this saved offline bookshelf change? No request will be sent.') end
        label=_('Remove saved change')
    else
        text=before and _('Save an offline request to remove this item from the cloud bookshelf? Downloaded files and local reading progress are kept. It will sync after reconnecting.')
            or _('Save an offline request to add this item to the cloud bookshelf? It will sync after reconnecting.')
        label=_('Save offline change')
    end
    local dialog
    dialog=require('ui/widget/confirmbox'):new{text=text,ok_text=label,keep_dialog_open=true,ok_callback=function()
        if host._membership_offline_dialog~=dialog or not current(host,owner) then return end
        host._membership_offline_dialog=nil;UI:close(dialog)
        local saved
        if pending then saved=queue(host):remove(pending)
        else
            local valid,fresh=pcall(host.library_db.getShelfStatus,host.library_db,id)
            if valid and type(fresh)=='table' and fresh.present==before and current(host,owner) then saved=queue(host):put(id,before,not before) end
        end
        if not saved then host:showInfo(_('Could not save the offline change. Refresh the bookshelf and try again.'));return end
        require('weread.ui.shelf_state').show(host,id)
        host:showInfo(pending and _('The saved offline change was removed.') or _('Offline bookshelf change saved. It will sync after reconnecting.'))
        if not pending then M.pump(host) end
    end,cancel_callback=function() if host._membership_offline_dialog==dialog then M.cancel_dialog(host) end end}
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if host._membership_offline_dialog==widget then host._membership_offline_dialog=nil end
        if on_close then return on_close(widget,...) end
    end
    host._membership_offline_dialog=dialog;UI:show(dialog);return true
end
return M
