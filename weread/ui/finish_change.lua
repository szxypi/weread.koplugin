local UI=require('ui/uimanager')
local Confirm=require('ui/widget/confirmbox')
local Util=require('weread.lib.plugin_util');local _=Util.tr
local T=require('ffi/util').template
local M={}
local function service(host)
    if not host._finish_change_service then
        host._finish_change_service=require('weread.lib.finish_change_service'):new{
            settings=host.settings,client=host.client,library=host.library_db,scheduler=UI,
            persist=function(snapshot) return host.library_db:cacheShelf(snapshot.books,snapshot.archive)==true end}
    end
    return host._finish_change_service
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
    return host._finish_change_ui==ctx and owner.account==host.library_db:accountKey() and owner.epoch==(host.discovery_epoch or 0)
        and owner.session==host._reader_session_gen and owner.document==(host.ui and host.ui.document)
        and owner.parent==host._book_detail_view and owner.menu==host._shelf_state_menu
end
function M.cancel(host)
    local ctx=host._finish_change_ui;host._finish_change_ui=nil
    if not ctx then return end
    service(host):cancel()
    if ctx.dialog then local dialog=ctx.dialog;ctx.dialog=nil;UI:close(dialog) end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end
local function message(reason)
    if reason=='login' then return _('Authorize or renew E-Ink login in settings, then try again.') end
    if reason=='pending' then return _('A previous finished-mark change is unconfirmed. Check it before making another change.') end
    return _('Could not prepare or save this finished-mark change. Check E-Ink login, network and storage, then try again.')
end
function M.open(host,id,resolving)
    M.cancel(host)
    if host._shelf_flag_change_ui then require('weread.ui.shelf_flag_change').cancel(host) end
    local private_pending,private_error=require('weread.ui.shelf_flag_change').pending(host)
    if private_pending then
        host:showInfo(_('A previous private-reading change is unconfirmed. Check it before making another change.'));return false
    end
    if private_error=='storage' then
        host:showInfo(_('Could not prepare or save this private-reading change. Check E-Ink login, network and storage, then try again.'));return false
    end
    if host._shelf_membership_ui then require('weread.ui.shelf_membership_write').cancel(host) end
    local member_pending,member_error
    if host.shelf_membership then member_pending,member_error=host.shelf_membership:pending() end
    if member_pending then
        host:showInfo(_('A previous bookshelf change is unconfirmed. Check it before making another change.'));return false
    end
    if member_error=='storage' then host:showInfo(message('storage'));return false end
    if not host:isNetworkConnected() then host:showOffline(_('Shelf status'));return false end
    local task=service(host);local ctx={owner=scope(host)};host._finish_change_ui=ctx
    local function finish(text,book)
        if not current(host,ctx) then return end
        M.cancel(host);require('weread.ui.shelf_state').show(host,book or id);host:showInfo(text)
    end
    local function busy(text)
        host:showBusy(text,function()
            if not current(host,ctx) then return end
            M.cancel(host);local pending=task:pending()
            require('weread.ui.shelf_state').show(host,id)
            if pending then host:showInfo(_('The finished-mark result is unconfirmed. No request will be resent. Check the pending change.')) end
        end);ctx.busy=host.busy_message
    end
    local function apply()
        if task.last_snapshot then host:applyShelfSnapshot(task.last_snapshot.books,task.last_snapshot.archive) end
    end
    busy(_('Checking finished mark and reading position…'))
    local started,reason=task:prepare(id,function() return current(host,ctx) end,function(plan,why)
        if not current(host,ctx) then return end
        if not plan then finish(message(why));return end
        if host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
        local book_id=plan.metadata.book_id;local book=host.library_db:getBook(book_id)
        local title=type(book)=='table' and book.title or _('Selected book')
        if type(title)~='string' or title=='' or #title>4096 then title=_('Selected book') end
        local text,label
        if plan.resolving then
            if not plan.current_present then text=T(_('“%1” is currently outside the cloud bookshelf. Keep this current state and finish checking the previous change?'),title)
            elseif plan.current_finished==nil then text=T(_('The cloud did not provide a finished mark for “%1”. Keep this state and finish checking the previous change?'),title)
            else text=T(plan.current_finished and _('“%1” is currently marked finished. Keep this state and finish checking the previous change?')
                or _('“%1” is currently marked unfinished. Keep this state and finish checking the previous change?'),title) end
            if not plan.position_unchanged then text=text..'\n\n'.._('The reading position has changed or could not be checked. Ending this check does not restore the earlier position.') end
            label=_('Keep current finished mark')
        else
            text=T(plan.metadata.desired and _('Mark “%1” as finished? This may change completion dates or reading history. Reading position is checked separately.')
                or _('Mark “%1” as unfinished? This may change completion dates or reading history. Reading position is checked separately.'),title)
            label=plan.metadata.desired and _('Mark as finished') or _('Mark as unfinished')
        end
        local dialog
        local function accept()
            if not current(host,ctx) or ctx.dialog~=dialog or not task:preview_current(plan) then return end
            ctx.dialog=nil;UI:close(dialog)
            if plan.resolving then
                local final
                final=Confirm:new{text=_('Finish this pending check without changing the cloud? This keeps the state just read, does not undo the request, and cannot rule out a delayed server change.'),
                    ok_text=_('Keep current finished mark'),keep_dialog_open=true,
                    cancel_callback=function() if ctx.dialog==final then M.cancel(host) end end,
                    ok_callback=function()
                        if ctx.dialog~=final or not current(host,ctx) then return end
                        ctx.dialog=nil;UI:close(final)
                        local accepted=task:accept_current(plan);if accepted then apply() end
                        finish(accepted and (plan.current_finished~=nil and _('The current finished mark is confirmed.')
                            or _('The current bookshelf state is confirmed.')) or message('storage'),book_id)
                    end}
                ctx.dialog=final;UI:show(final);return
            end
            busy(_('Updating finished mark…\nCancelling may leave the result unconfirmed.'))
            local committed,error_=task:commit(plan,function(result,finished)
                if not current(host,ctx) then return end
                local text_
                if not finished then text_=_('The finished-mark result is unconfirmed. No request will be resent. Check the pending change.')
                elseif result.kind=='confirmed' or result.kind=='noop' then
                    apply();text_=_('The finished mark was verified by reading the cloud bookshelf again.')
                elseif result.kind=='changed' then text_=_('The bookshelf or reading position changed after confirmation. No finished-mark request was sent. Check again.')
                else text_=message(result.kind) end
                finish(text_,book_id)
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
