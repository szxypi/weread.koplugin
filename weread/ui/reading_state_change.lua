local UI=require('ui/uimanager')
local Confirm=require('ui/widget/confirmbox')
local _=require('weread.lib.plugin_util').tr
local Paused=require('weread.ui.offline_paused')
local T=require('ffi/util').template
local M={}
local function service(host)
    if not host._reading_state_change_service then
        host._reading_state_change_service=require('weread.lib.reading_state_change_service'):new{
            settings=host.settings,client=host.client,library=host.library_db,scheduler=UI,
            persist=function(snapshot) return host.library_db:cacheShelf(snapshot.books,snapshot.archive)==true end}
    end
    return host._reading_state_change_service
end
function M.pending(host)
    if not host.client or not host.library_db or not host.library_db.open then return nil end
    return service(host):pending()
end
local function scope(host)
    return {account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,session=host._reader_session_gen,
        document=host.ui and host.ui.document,parent=host._book_detail_view,menu=host._shelf_state_menu}
end
local function current(host,ctx)
    local owner=ctx.owner
    return host._reading_state_change_ui==ctx and owner.account==host.library_db:accountKey()
        and owner.epoch==(host.discovery_epoch or 0) and owner.session==host._reader_session_gen
        and owner.document==(host.ui and host.ui.document) and owner.parent==host._book_detail_view
        and owner.menu==host._shelf_state_menu
end
function M.cancel(host)
    local ctx=host._reading_state_change_ui;host._reading_state_change_ui=nil
    if not ctx then return end
    service(host):cancel()
    if ctx.dialog then local dialog=ctx.dialog;ctx.dialog=nil;UI:close(dialog) end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    Paused.wake(host)
end
function M.block(host)
    if host._reading_state_change_ui then M.cancel(host) end
    local pending,reason=M.pending(host)
    if pending or reason then
        host:showInfo(_(pending and 'A previous started-reading change is unconfirmed. Check it before making another change.'
            or 'Could not check previous started-reading changes. Check storage and try again.'))
        return true
    end
    return false
end
local function message(reason)
    if reason=='login' then return _('Authorize or renew E-Ink login in settings, then try again.') end
    if reason=='pending' then return _('A previous started-reading change is unconfirmed. Check it before making another change.') end
    return _('Could not prepare or save the started-reading change. Check E-Ink login, network and storage, then try again.')
end
function M.open(host,id,resolving)
    local reading=package.loaded['weread.ui.reading_state']
    if reading then reading.cancel(host) end
    local member_offline=package.loaded['weread.ui.membership_offline']
    if member_offline then member_offline.cancel_sync(host,true) end
    local finish_offline=package.loaded['weread.ui.finish_offline']
    if finish_offline then finish_offline.cancel_sync(host,true) end
    M.cancel(host)
    if host._shelf_flag_change_ui then require('weread.ui.shelf_flag_change').cancel(host) end
    local private,private_error=require('weread.ui.shelf_flag_change').pending(host)
    if private or private_error then
        host:showInfo(_(private and 'Check the pending shelf-status change before making another change.'
            or 'Could not check previous shelf changes. Check storage and try again.'));return false
    end
    if host._finish_change_ui then require('weread.ui.finish_change').cancel(host) end
    local finished,finished_error=require('weread.ui.finish_change').pending(host)
    if finished or finished_error then
        host:showInfo(_(finished and 'Check the pending shelf-status change before making another change.'
            or 'Could not check previous shelf changes. Check storage and try again.'));return false
    end
    if host._shelf_membership_ui then require('weread.ui.shelf_membership_write').cancel(host) end
    if host.shelf_membership then
        local member,member_error=host.shelf_membership:pending()
        if member or member_error then
            host:showInfo(_(member and 'A previous bookshelf change is unconfirmed. Check it before making another change.'
                or 'Could not check previous shelf changes. Check storage and try again.'));return false
        end
    end
    if not host:isNetworkConnected() then host:showOffline(_('Shelf status'));return false end
    local task=service(host);local ctx={owner=scope(host)}
    ctx.cache=require('weread.lib.reading_state_cache'):new(host.library_db,ctx.owner.account)
    local pending_record=resolving and task:pending()
    ctx.cache_id=pending_record and pending_record.metadata and pending_record.metadata.book_id or id
    ctx.cached=ctx.cache:read(ctx.cache_id);host._reading_state_change_ui=ctx
    local function finish(text,book)
        if not current(host,ctx) then return end
        M.cancel(host);require('weread.ui.shelf_state').show(host,book or id);host:showInfo(text)
    end
    local function busy(text)
        host:showBusy(text,function()
            if not current(host,ctx) then return end
            M.cancel(host);local pending=task:pending()
            require('weread.ui.shelf_state').show(host,id)
            if pending then host:showInfo(_('The started-reading change is unconfirmed. It will not be sent again automatically.')) end
        end);ctx.busy=host.busy_message
    end
    local function apply()
        if task.last_snapshot then host:applyShelfSnapshot(task.last_snapshot.books,task.last_snapshot.archive) end
    end
    busy(_('Checking started-reading status and position…'))
    local started,reason=task:prepare(id,function() return current(host,ctx) end,function(plan,why)
        if not current(host,ctx) then return end
        if not plan then finish(message(why));return end
        if host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
        local book_id=plan.metadata.book_id;local book=host.library_db:getBook(book_id)
        local title=type(book)=='table' and book.title or _('Selected book')
        if type(title)~='string' or title=='' or #title>4096 then title=_('Selected book') end
        local text,label
        if plan.resolving then
            if not plan.current_present then
                text=T(_('“%1” is currently outside the cloud bookshelf. Keep this current state and finish checking the previous change?'),title)
            elseif plan.current_started==nil then
                text=T(_('WeRead did not provide a started-reading status for “%1”. Keep this state and finish checking the previous change?'),title)
            else
                text=T(plan.current_started and _('WeRead currently records “%1” as started. Keep this state and finish checking the previous change?')
                    or _('WeRead currently records “%1” as not started. Keep this state and finish checking the previous change?'),title)
            end
            if not plan.position_unchanged then text=text..'\n\n'.._('The reading position has changed or could not be checked. Ending this check does not restore the earlier position.') end
            label=_('Keep current reading status')
        else
            text=T(plan.metadata.desired and _('Mark “%1” as started? WeRead may change the start time or reading history. Reading position is checked separately.')
                or _('Mark “%1” as not started? WeRead may change the start time or reading history. Reading position is checked separately.'),title)
            label=plan.metadata.desired and _('Mark as started') or _('Mark as not started')
        end
        local dialog
        local function accept()
            if not current(host,ctx) or ctx.dialog~=dialog or not task:preview_current(plan) then return end
            ctx.dialog=nil;UI:close(dialog)
            if plan.resolving then
                local final
                final=Confirm:new{text=_('Finish this pending check without changing the cloud? This keeps the state just read, does not undo the request, and cannot rule out a delayed server change.'),
                    ok_text=_('Keep current reading status'),keep_dialog_open=true,
                    cancel_callback=function() if ctx.dialog==final then M.cancel(host) end end,
                    ok_callback=function()
                        if ctx.dialog~=final or not current(host,ctx) then return end
                        ctx.dialog=nil;UI:close(final)
                        local accepted=task:accept_current(plan)
                        if accepted then
                            apply()
                            if book_id==ctx.cache_id and plan.current_present and type(plan.current_started)=='boolean' then
                                pcall(ctx.cache.write,ctx.cache,book_id,plan.current_started,ctx.cached)
                            end
                        end
                        finish(accepted and _('The current reading status was checked.') or message('storage'),book_id)
                    end}
                ctx.dialog=final;UI:show(final);return
            end
            busy(_('Updating started-reading status…\nCancelling may leave the result unconfirmed.'))
            local committed,error_=task:commit(plan,function(result,finished_ok)
                if not current(host,ctx) then return end
                local notice
                if not finished_ok then notice=_('The started-reading change is unconfirmed. It will not be sent again automatically.')
                elseif result.kind=='confirmed' or result.kind=='noop' then
                    apply()
                    if book_id==ctx.cache_id and type(result.observed)=='table' and type(plan.metadata.desired)=='boolean' then
                        pcall(ctx.cache.write,ctx.cache,book_id,plan.metadata.desired,ctx.cached)
                    end
                    notice=_('The current started-reading status was verified in WeRead.')
                elseif result.kind=='changed' then notice=_('The bookshelf or reading state changed after confirmation. No request was sent. Check again.')
                else notice=message(result.kind) end
                finish(notice,book_id)
            end)
            if not committed then finish(message(error_),book_id) end
        end
        dialog=Confirm:new{text=text,ok_text=label,keep_dialog_open=true,ok_callback=accept,
            cancel_callback=function() if ctx.dialog==dialog then M.cancel(host) end end}
        ctx.dialog=dialog;UI:show(dialog)
    end,resolving)
    if not started then finish(message(reason));return false end
    return true
end
return M
