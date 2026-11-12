local UI=require('ui/uimanager')
local Confirm=require('ui/widget/confirmbox')
local Util=require('weread.lib.plugin_util');local _=Util.tr
local T=require('ffi/util').template
local M={}
local function current(host,ctx)
    local sync=host.progress_sync
    return host._native_position_review_ui==ctx and sync.is_online() and sync:_session_current(ctx.scope)
        and ctx.scope.navigation_generation==sync.navigation_generation
        and ctx.document==sync.get_document() and ctx.marker==sync:_recovery_marker()
end
function M.cancel(host)
    local ctx=host._native_position_review_ui;host._native_position_review_ui=nil
    if not ctx then return end
    ctx.task:cancel()
    if ctx.dialog then local dialog=ctx.dialog;ctx.dialog=nil;UI:close(dialog) end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end
function M.view_changed(host)
    local ctx=host._native_position_review_ui
    if ctx and (not current(host,ctx) or ctx.token and not ctx.task:current(ctx.token)) then M.cancel(host) end
end
local function error_text(reason)
    if reason=='login' then return _('Check E-Ink login in account settings, then check the pending position again.') end
    if reason=='changed' then return _('Cloud reading state changed during the check. The previous record and local position are kept. Check again.') end
    return _('Could not check or archive the previous sync. The record and local position are kept. Check network, login and storage, then try again.')
end
function M.open(host)
    if not host.library_db or not host.library_db.open or not host.source_upload then return false end
    M.cancel(host)
    local task=require('weread.lib.native_position_review'):new{settings=host.settings,client=host.client,library=host.library_db,scheduler=UI}
    local record,reason=task:pending()
    if reason then host:showInfo(error_text(reason));return true end
    if not record then return false end
    local sync=host.progress_sync
    if sync.uploading or sync.pulling then host:showInfo(_('A progress sync is still running. Wait for it to finish, then check again.'));return true end
    if not sync.is_online() then host:showInfo(error_text('offline'));return true end
    if host.source_upload then host.source_upload:cancel() end
    sync:begin_native_review()
    local ctx={task=task,scope=sync:_scope(),document=sync.get_document(),marker=sync:_recovery_marker()}
    if not ctx.document or not ctx.marker then host:showInfo(error_text('unavailable'));return true end
    host._native_position_review_ui=ctx
    local function cancel() if host._native_position_review_ui==ctx then M.cancel(host) end end
    local function fail(why)
        if host._native_position_review_ui~=ctx then return end
        M.cancel(host);if why~='cancelled' then host:showInfo(error_text(why)) end
    end
    local title=_('Previous book');local book=host.library_db:getBook(record.metadata.book_id)
    if type(book)=='table' and type(book.title)=='string' and #book.title>0 and #book.title<=4096 then title=book.title end
    local function inspect()
        if not current(host,ctx) then cancel();return end
        if ctx.dialog then local dialog=ctx.dialog;ctx.dialog=nil;UI:close(dialog) end
        host:showBusy(_('Checking the current cloud position…'),cancel);ctx.busy=host.busy_message
        local started,why=task:start(function() return current(host,ctx) end,function(result,token)
            if host._native_position_review_ui~=ctx then return end
            if not current(host,ctx) then cancel();return end
            if host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
            if result.kind~='observed' then fail(result.kind);return end
            ctx.token=token
            local text=T(_('Current cloud position for “%1”: %2%. Archiving keeps the old request result and your local position; it does not resend or undo anything. A delayed cloud change may still arrive.'),title,string.format('%.0f',result.percent))
            if result.phase=='pending' then text=_('The previous request has no confirmed receipt. A matching cloud position does not prove that request succeeded.')..'\n\n'..text end
            local dialog
            dialog=Confirm:new{title=_('Review previous sync'),text=text,ok_text=_('Archive and compare again'),keep_dialog_open=true,
                cancel_text=_('Keep pending record'),cancel_callback=cancel,
                ok_callback=function()
                    if not current(host,ctx) or ctx.dialog~=dialog or not task:current(token) then cancel();return end
                    local accepted=task:archive(token);M.cancel(host)
                    if not accepted then host:showInfo(error_text('storage'));return end
                    sync:compare_after_native_review()
                end}
            ctx.dialog=dialog;UI:show(dialog)
        end,record)
        if not started then fail(why) end
    end
    ctx.dialog=Confirm:new{title=_('Review previous sync'),
        text=T(_('A previous position sync for “%1” needs review. Check the current cloud state without resending the old request?'),title),
        ok_text=_('Check cloud position'),keep_dialog_open=true,ok_callback=inspect,
        cancel_callback=cancel}
    UI:show(ctx.dialog);return true
end
return M
