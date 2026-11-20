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
function M.list(host)
    if not host.library_db or not host.library_db.open then return nil,'storage' end
    return queue(host):list()
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
-- Only copy the freshly persisted cloud flag into existing page models. This
-- never changes the database or other book fields, including local progress.
function M.reconcile_view(host,view)
    local dirty=view and view._finish_dirty
    if not dirty then return true end
    for id in pairs(dirty) do
        local ok,state=pcall(host.library_db.getShelfStatus,host.library_db,id)
        if not ok or type(state)~='table' then return false end
        if state.present==true and type(state.book)=='table' then
            local value=Flags.display(state.book,'finished')
            if type(value)=='boolean' then
                for _,book in ipairs(view.books or {}) do
                    if tostring(book.bookId or book.book_id or '')==id then book.finishReading=value and 1 or 0 end
                end
            end
        end
        dirty[id]=nil
    end
    view._finish_dirty=nil
    return true
end
function M.redraw_preserving_focus(host,view,render)
    local selected=view.selected
    local x,y=selected and selected.x,selected and selected.y
    render()
    local fresh=host.shelf_view
    if fresh and fresh~=view and type(x)=='number' and type(y)=='number'
        and fresh.layout and fresh.layout[y] and fresh.layout[y][x] and fresh.moveFocusTo then
        fresh:moveFocusTo(x,y,require('ui/widget/focusmanager').FOCUS_ONLY_ON_NT)
    end
end
function M.flush_view(host)
    local view=host.shelf_view
    if not view or view._shelf_closed or not view._finish_dirty or type(view._finish_redraw)~='function' then return end
    -- The detail screen owns focus. Its existing return path rebuilds the
    -- retained shelf and calls reconcile_view after the detail is dismissed.
    if host._book_detail_view or host._shelf_state_menu then return end
    local current=require('weread.ui.page_scope').capture(host,view)
    require('weread.ui.shelf_popup').redrawForMetadata(host,view,function()
        if not current() or host._book_detail_view or host._shelf_state_menu or not M.reconcile_view(host,view) then return end
        view._finish_redraw()
    end)
end
function M.refresh_view(host,id)
    local view=host.shelf_view
    if not view or view._shelf_closed or type(view._finish_redraw)~='function' then return end
    view._finish_dirty=view._finish_dirty or {};view._finish_dirty[id]=true
    M.flush_view(host)
end
local function clear_retry(host)
    local retry=host._finish_offline_retry;host._finish_offline_retry=nil
    if retry and retry.timer then UI:unschedule(retry.timer) end
end
function M.cancel_sync(host,preserve_retry)
    if not preserve_retry then clear_retry(host) end
    if host._finish_offline_sync then host._finish_offline_sync:cancel() end
    host._finish_offline_sync=nil;host._finish_offline_account=nil
end
local function ui_blocked(host)
    return host._finish_change_ui or host._shelf_flag_change_ui or host._shelf_membership_ui
        or host._finish_offline_dialog or host._membership_offline_dialog
        or (host._membership_offline_sync and host._membership_offline_sync.job)
end
local function retry_later(host,account,entry)
    if type(entry)~='table' or entry.phase~='queued' or type(entry.id)~='string' then return end
    local retry=host._finish_offline_retry
    if not retry or retry.account~=account or retry.id~=entry.id or retry.book_id~=entry.book_id then
        clear_retry(host)
        retry={account=account,id=entry.id,book_id=entry.book_id,attempts=0}
        host._finish_offline_retry=retry
    end
    if retry.timer then return end
    if retry.attempts>=2 then
        if not retry.notified and host.showTransientInfo then
            retry.notified=true;host:showTransientInfo(_('Offline finished mark could not sync. Refresh the bookshelf to try again.'),5)
        end
        return
    end
    retry.attempts=retry.attempts+1
    local timer
    timer=function()
        if host._finish_offline_retry~=retry or retry.timer~=timer then return end
        retry.timer=nil
        if host.library_db:accountKey()~=account then clear_retry(host);return end
        local current,err=queue(host):get(entry.book_id)
        if err or not current or current.id~=entry.id or current.phase~='queued' then
            clear_retry(host)
            if not err then M.pump(host) end
            return
        end
        if not M.pump(host) and ui_blocked(host) and host._finish_offline_retry==retry then
            retry.waiting_ui=true
        end
    end
    retry.timer=timer
    UI:scheduleIn(retry.attempts==1 and 30 or 60,timer)
end
local function allowed(host,account)
    if not account or host.library_db:accountKey()~=account or not host:isNetworkConnected()
        or ui_blocked(host) then return false end
    local private,private_error=require('weread.ui.shelf_flag_change').pending(host)
    if private or private_error then return false end
    if host.shelf_membership then
        local member,member_error=host.shelf_membership:pending()
        if member or member_error then return false end
    end
    return true
end
function M.pump(host,force)
    if not host.library_db or not host.library_db.open or not host.client then return false end
    local account=host.library_db:accountKey()
    if host._finish_offline_sync and host._finish_offline_account~=account then M.cancel_sync(host) end
    if not allowed(host,account) then return false end
    local retry=host._finish_offline_retry
    if retry and retry.timer then
        if force~=true then return false end
        UI:unschedule(retry.timer);retry.timer=nil
    end
    if retry then retry.waiting_ui=nil end
    if not host._finish_offline_sync then
        host._finish_offline_account=account
        host._finish_offline_sync=require('weread.lib.finish_queue_sync'):new{
            queue=queue(host),service=require('weread.ui.finish_change').service(host),
            allowed=function() return allowed(host,account) end,
            notify=function(phase,entry)
                if host._finish_offline_account~=account then return end
                if phase=='confirmed' or phase=='unconfirmed' then clear_retry(host) end
                if (phase=='confirmed' or phase=='unconfirmed') and entry then M.refresh_view(host,entry.book_id) end
                if phase=='confirmed' then
                    if host.showTransientInfo then host:showTransientInfo(_('Offline finished mark synced.'),3) end
                    UI:nextTick(function() if host._finish_offline_account==account then M.pump(host);require('weread.ui.membership_offline').pump(host) end end)
                elseif phase=='unconfirmed' and host.showTransientInfo then
                    host:showTransientInfo(_('An offline finished mark needs review. It will not be sent again.'),5)
                elseif phase=='retryable' then
                    retry_later(host,account,entry)
                elseif phase=='login' and host.showTransientInfo then
                    host:showTransientInfo(_('Offline finished mark needs E-Ink authorization. Renew it, then refresh the bookshelf.'),5)
                elseif phase=='rate_limited' and host.showTransientInfo then
                    host:showTransientInfo(_('WeRead is limiting requests. Refresh the bookshelf later to retry the offline mark.'),5)
                end
            end,
        }
    end
    return host._finish_offline_sync:pump()
end
-- A timer which became due while a conflicting dialog was open is resumed
-- only when that dialog closes, with the original account and queue token.
function M.resume_retry(host)
    local retry=host._finish_offline_retry
    if not retry or not retry.waiting_ui or retry.wake_scheduled then return end
    retry.wake_scheduled=true
    UI:nextTick(function()
        retry.wake_scheduled=nil
        if host._finish_offline_retry~=retry or not retry.waiting_ui then return end
        if not host.library_db or host.library_db:accountKey()~=retry.account then clear_retry(host);return end
        local entry,err=queue(host):get(retry.book_id)
        if err or not entry or entry.id~=retry.id or entry.phase~='queued' then clear_retry(host);return end
        M.pump(host)
    end)
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
        if not saved then
            host:showInfo(_('Could not save the offline change. Refresh the bookshelf and try again.'))
            M.resume_retry(host);return
        end
        require('weread.ui.shelf_state').show(host,id)
        host:showInfo(pending and _('The saved offline change was removed.') or _('Offline finished mark saved. It will sync after reconnecting.'))
        if not pending then M.pump(host) end
        M.resume_retry(host)
    end,cancel_callback=function()
        if host._finish_offline_dialog==dialog then host._finish_offline_dialog=nil;UI:close(dialog);M.resume_retry(host) end
    end}
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if host._finish_offline_dialog==widget then host._finish_offline_dialog=nil;M.resume_retry(host) end
        if on_close then return on_close(widget,...) end
    end
    host._finish_offline_dialog=dialog;UI:show(dialog);return true
end
function M.cancel_dialog(host)
    local dialog=host._finish_offline_dialog;host._finish_offline_dialog=nil
    if dialog then UI:close(dialog);M.resume_retry(host) end
end
return M
