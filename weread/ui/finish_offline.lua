-- Offline queue UI and lifecycle bridge. No queued action is sent twice.
local UI=require('ui/uimanager')
local Flags=require('weread.lib.shelf_flags')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function queue(host)
    if not host._finish_offline_queue then
        host._finish_offline_queue=require('weread.lib.finish_queue_store'):new(host.library_db)
    end
    return host._finish_offline_queue
end
function M.get(host,id)
    if not host.library_db or not host.library_db.open then return nil end
    return queue(host):get(id)
end
function M.snapshot(host)
    if not host.library_db or not host.library_db.open then return nil end
    local entries=queue(host):list()
    if not entries then return nil end
    local result={}
    for _,entry in ipairs(entries) do result[entry.book_id]={desired=entry.desired,phase=entry.phase} end
    return result
end
function M.cancel_sync(host)
    if host._finish_offline_sync then host._finish_offline_sync:cancel() end
    host._finish_offline_sync=nil;host._finish_offline_account=nil
end
local function allowed(host,account)
    if not account or host.library_db:accountKey()~=account or not host:isNetworkConnected()
        or host._finish_change_ui or host._shelf_flag_change_ui or host._shelf_membership_ui or host._finish_offline_dialog then return false end
    local private,private_error=require('weread.ui.shelf_flag_change').pending(host)
    if private or private_error then return false end
    if host.shelf_membership then
        local member,member_error=host.shelf_membership:pending()
        if member or member_error then return false end
    end
    return true
end
function M.pump(host)
    if not host.library_db or not host.library_db.open or not host.client then return false end
    local account=host.library_db:accountKey()
    if host._finish_offline_sync and host._finish_offline_account~=account then M.cancel_sync(host) end
    if not allowed(host,account) then return false end
    if not host._finish_offline_sync then
        host._finish_offline_account=account
        host._finish_offline_sync=require('weread.lib.finish_queue_sync'):new{
            queue=queue(host),service=require('weread.ui.finish_change').service(host),
            allowed=function() return allowed(host,account) end,
            notify=function(phase)
                if host._finish_offline_account~=account then return end
                if phase=='confirmed' then
                    if host.showTransientInfo then host:showTransientInfo(_('Offline finished mark synced.'),3) end
                    UI:nextTick(function() M.pump(host) end)
                elseif phase=='unconfirmed' and host.showTransientInfo then
                    host:showTransientInfo(_('An offline finished mark needs review. It will not be sent again.'),5)
                end
            end,
        }
    end
    return host._finish_offline_sync:pump()
end
local function context(host)
    return {account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,session=host._reader_session_gen,
        document=host.ui and host.ui.document,parent=host._book_detail_view,menu=host._shelf_state_menu}
end
local function current(host,owner)
    return owner.account and owner.account==host.library_db:accountKey() and owner.epoch==(host.discovery_epoch or 0)
        and owner.session==host._reader_session_gen and owner.document==(host.ui and host.ui.document)
        and owner.parent==host._book_detail_view and owner.menu==host._shelf_state_menu
end
function M.open(host,id)
    local owner=context(host)
    if not current(host,owner) then return false end
    local pending,reason=queue(host):get(id)
    if reason then host:showInfo(_('Could not read offline finished marks.'));return false end
    local ok,snapshot=pcall(host.library_db.getShelfStatus,host.library_db,id)
    local before
    if ok and snapshot and snapshot.present==true then before=Flags.display(snapshot.book,'finished') end
    if not pending and type(before)~='boolean' then
        host:showInfo(_('The saved bookshelf has no verified finished mark for this book. Refresh it online first.'));return false
    end
    local text,label
    if pending then
        if pending.phase=='dispatching' then
            local active,err=require('weread.ui.finish_change').pending(host)
            if active or err then
                host:showInfo(_('This offline change may have been sent. Check the pending finished-mark change first.'));return false
            end
            text=_('This offline change may have been sent. Remove its local record without retrying? Check the current cloud status separately; a delayed change may still appear.')
        else text=_('Cancel this saved offline finished-mark change? No request will be sent.') end
        label=_('Remove saved change')
    else
        text=T(before and _('Save an offline request to mark this book unfinished? It will sync after reconnecting.')
            or _('Save an offline request to mark this book finished? It will sync after reconnecting.'))
        label=_('Save offline change')
    end
    local dialog
    dialog=require('ui/widget/confirmbox'):new{text=text,ok_text=label,keep_dialog_open=true,ok_callback=function()
        if host._finish_offline_dialog~=dialog or not current(host,owner) then return end
        host._finish_offline_dialog=nil;UI:close(dialog)
        local saved
        if pending then saved=queue(host):remove(pending)
        else
            local valid,fresh=pcall(host.library_db.getShelfStatus,host.library_db,id)
            if valid and fresh and fresh.present==true and Flags.display(fresh.book,'finished')==before and current(host,owner) then
                saved=queue(host):put(id,before,not before)
            end
        end
        if not saved then host:showInfo(_('Could not save the offline change. Refresh the bookshelf and try again.'));return end
        require('weread.ui.shelf_state').show(host,id)
        host:showInfo(pending and _('The saved offline change was removed.') or _('Offline finished mark saved. It will sync after reconnecting.'))
        if not pending then M.pump(host) end
    end,cancel_callback=function()
        if host._finish_offline_dialog==dialog then host._finish_offline_dialog=nil;UI:close(dialog) end
    end}
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if host._finish_offline_dialog==widget then host._finish_offline_dialog=nil end
        if on_close then return on_close(widget,...) end
    end
    host._finish_offline_dialog=dialog;UI:show(dialog);return true
end
function M.cancel_dialog(host)
    local dialog=host._finish_offline_dialog;host._finish_offline_dialog=nil
    if dialog then UI:close(dialog) end
end
return M
