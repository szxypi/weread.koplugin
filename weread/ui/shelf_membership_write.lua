local UI=require('ui/uimanager')
local Confirm=require('ui/widget/confirmbox')
local Util=require('weread.lib.plugin_util')
local _=Util.tr
local T=require('ffi/util').template
local Access=require('weread.lib.native_read_access')
local Recovery=require('weread.lib.native_read_recovery')
local M={}
local function capture(settings,store)
    local native=Access.capture(settings,store)
    return native and {native=native,base_revision=''} or nil
end
local function scope(host)
    return {account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,session=host._reader_session_gen,
        document=host.ui and host.ui.document,parent=host._book_detail_view,menu=host._shelf_state_menu}
end
local function current(host,ctx)
    local owner=ctx.owner
    return host._shelf_membership_ui==ctx and owner.account==host.library_db:accountKey()
        and owner.epoch==(host.discovery_epoch or 0) and owner.session==host._reader_session_gen
        and owner.document==(host.ui and host.ui.document) and owner.parent==host._book_detail_view
        and owner.menu==host._shelf_state_menu
end
function M.cancel(host)
    local ctx=host._shelf_membership_ui;host._shelf_membership_ui=nil
    if not ctx then return end
    Recovery.cancel(host,ctx)
    host.shelf_membership:cancel()
    if ctx.dialog then local view=ctx.dialog;ctx.dialog=nil;UI:close(view) end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end
local function error_text(reason)
    if reason=='login' then return _('Authorize or renew E-Ink login in settings, then try again.') end
    if reason=='pending' then return _('A previous bookshelf change is unconfirmed. Check it before making another change.') end
    if reason=='unconfirmed' then return _('The bookshelf change could not be confirmed. It will not be sent again automatically. Check the pending change before trying again.') end
    return _('Could not prepare or save this bookshelf change. Check login, network and storage, then try again.')
end
local function cache(host,snapshot)
    if not snapshot then return false end
    local ok,saved=pcall(host.library_db.cacheShelf,host.library_db,snapshot.books,snapshot.archive)
    if ok and saved then host:applyShelfSnapshot(snapshot.books,snapshot.archive);return true end
    return false
end
function M.open(host,id,resolving)
    M.cancel(host)
    if not host:isNetworkConnected() then host:showOffline(_('Shelf status'));return false end
    local ctx={owner=scope(host)};host._shelf_membership_ui=ctx
    local function fail(reason)
        if not current(host,ctx) then return end
        M.cancel(host);require('weread.ui.shelf_state').show(host,id);host:showInfo(error_text(reason))
    end
    local function busy(text)
        host:showBusy(text,function()
            if not current(host,ctx) then return end
            local pending=host.shelf_membership:pending()
            M.cancel(host)
            require('weread.ui.shelf_state').show(host,id)
            if pending then host:showInfo(error_text('unconfirmed')) end
        end)
        ctx.busy=host.busy_message
    end
    local launch
    local function empty_journal()
        local pending,reason=host.shelf_membership:pending()
        return not pending and not reason
    end
    local function recover(selected)
        if not empty_journal() then fail('login');return end
        local called,started=pcall(Recovery.start,host,ctx,{native=selected,base_revision=''},{capture=capture,
            is_current=function() return current(host,ctx) and empty_journal() end,
            stale=function() if host._shelf_membership_ui==ctx then M.cancel(host) end end,
            complete=function(success)
                if success then launch() else fail('login') end
            end})
        if not called or not started then fail('login') end
    end
    local function prepared(plan,why,selected)
        if not current(host,ctx) then return end
        if not plan and why=='native_expired' then recover(selected);return end
        if not plan then fail(why);return end
        if host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
        local book=host.library_db:getBook(plan.book_id)
        local title=type(book)=='table' and book.title or _('Selected book')
        if type(title)~='string' or title=='' or #title>4096 then title=_('Selected book') end
        local text,label
        if plan.resolving then
            text=T(plan.before and _('“%1” is currently in the cloud bookshelf. Keep this current state and finish checking the previous change?')
                or _('“%1” is currently outside the cloud bookshelf. Keep this current state and finish checking the previous change?'),title)
            label=_('Accept current shelf state')
        elseif plan.before then
            text=T(_('Remove “%1” from the cloud bookshelf? Downloaded files and local reading progress are kept.'),title)
            label=_('Remove from cloud bookshelf')
        else text=T(_('Add “%1” to the cloud bookshelf?'),title);label=_('Add to cloud bookshelf') end
        local dialog
        dialog=Confirm:new{text=text,ok_text=label,keep_dialog_open=true,
            cancel_callback=function() if ctx.dialog==dialog then M.cancel(host) end end,
            ok_callback=function()
                if ctx.dialog~=dialog or not current(host,ctx) then return end
                ctx.dialog=nil;UI:close(dialog)
                if plan.resolving then
                    local accepted=host.shelf_membership:accept_current(plan)
                    local saved=accepted and cache(host,plan.snapshot)
                    M.cancel(host);require('weread.ui.shelf_state').show(host,plan.book_id)
                    host:showInfo(accepted and (saved and _('The current bookshelf state is confirmed.')
                        or _('The cloud bookshelf was checked, but its local snapshot could not be saved. Refresh shelf status.')) or error_text('storage'))
                    return
                end
                busy(_('Updating cloud bookshelf…\nCancelling may leave the result unconfirmed.'))
                local sent,error_=host.shelf_membership:commit(plan,function(result,finished,used)
                    if not current(host,ctx) then return end
                    if finished and result.kind=='login' and result.attempted==false then recover(used);return end
                    local saved=cache(host,result.snapshot)
                    M.cancel(host);require('weread.ui.shelf_state').show(host,plan.book_id)
                    local message
                    if not finished then message=error_text('unconfirmed')
                    elseif result.kind=='confirmed' or result.kind=='noop' then
                        message=saved and (plan.operation=='add' and _('Added to the cloud bookshelf.') or _('Removed from the cloud bookshelf.'))
                            or _('The cloud bookshelf was checked, but its local snapshot could not be saved. Refresh shelf status.')
                    elseif result.kind=='changed' then message=_('The bookshelf changed after confirmation. No change was sent. Check its current state and try again.')
                    else message=error_text('unavailable') end
                    host:showInfo(message)
                end)
                if not sent then fail(error_) end
            end}
        ctx.dialog=dialog;UI:show(dialog)
    end
    launch=function()
        if not current(host,ctx) then return false end
        busy(_('Checking cloud bookshelf…\nTap or press a key to cancel.'))
        local started,reason=host.shelf_membership:prepare(id,function() return current(host,ctx) end,prepared,resolving)
        if not started then fail(reason) end
        return started
    end
    return launch()
end
return M
