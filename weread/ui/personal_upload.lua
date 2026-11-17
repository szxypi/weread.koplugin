-- Native file chooser and cancellable upload; unknown outcomes stay pending.
local Model=require('weread.lib.personal_upload')
local Journal=require('weread.lib.personal_upload_journal')
local Access=require('weread.lib.native_read_access')
local Members=require('weread.lib.shelf_membership_write')
local Read=require('weread.lib.read_access')
local UI=require('ui/uimanager')
local Confirm=require('ui/widget/confirmbox')
local _=require('weread.lib.plugin_util').tr
local T=require('ffi/util').template
local M={}
local function owner(host)
    return {account=host.library_db and host.library_db:accountKey(),epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document,file=host.ui and host.ui.document and host.ui.document.file,
        session=host._reader_session_gen}
end
local function current(host,ctx)
    local scope=ctx.owner
    return host._personal_upload_ui==ctx and scope.account~=nil and scope.account==(host.library_db and host.library_db:accountKey())
        and scope.epoch==(host.discovery_epoch or 0) and scope.document==(host.ui and host.ui.document)
        and scope.file==(host.ui and host.ui.document and host.ui.document.file) and scope.session==host._reader_session_gen
end
function M.cancel(host)
    local ctx=host._personal_upload_ui;host._personal_upload_ui=nil
    if not ctx then return end
    if host.personal_upload_worker then host.personal_upload_worker:cancel() end
    if ctx.dialog then UI:close(ctx.dialog);ctx.dialog=nil end
    if ctx.chooser then UI:close(ctx.chooser);ctx.chooser=nil end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end
local function message(host,kind)
    host:showInfo(kind=='login' and _('Check E-Ink authorization in account settings, then try again.')
        or kind=='unconfirmed' and _('The upload result is unconfirmed. Check the cloud bookshelf before clearing the pending record; it will not be sent again automatically.')
        or _('Could not upload this book. Check its format, size, login, network and storage, then try again.'))
end
local function confirmed(result)
    if type(result)~='table' or result.kind~='confirmed' or result.put_attempted~=true or result.notify_attempted~=true
        or not Read.display_book_id(result.book_id) or type(result.before_members_digest)~='string'
        or #result.before_members_digest~=64 or not result.before_members_digest:match('^[a-f0-9]+$')
        or type(result.protected_digest)~='string' or #result.protected_digest~=64
        or not result.protected_digest:match('^[a-f0-9]+$') then return false end
    local members=Members.members(result.snapshot)
    if not members or Members.contains(result.snapshot,result.book_id)~=true then return false end
    local others={};for _i,id in ipairs(members) do if id~=result.book_id then others[#others+1]=id end end
    return Members.digest(others)==result.before_members_digest
        and Members.protected(result.snapshot,result.book_id)==result.protected_digest
end
M.confirmed=confirmed
local function pending(host,ctx,record)
    local dialog
    dialog=require('ui/widget/buttondialog'):new{title=_('Previous upload needs review'),buttons={
        {{text=_('Open cloud bookshelf'),callback=function()
            if not current(host,ctx) or ctx.dialog~=dialog then return end
            M.cancel(host);host:showBookshelf()
        end}},
        {{text=_('Clear pending upload record'),callback=function()
            if not current(host,ctx) or ctx.dialog~=dialog then return end
            ctx.dialog=nil;UI:close(dialog)
            local confirm
            confirm=Confirm:new{text=_('The previous upload may have completed. Check the cloud bookshelf first. Clear this local record? This does not resend or undo the upload.'),
                ok_text=_('Clear pending record'),cancel_callback=function() if current(host,ctx) then M.cancel(host) end end,
                ok_callback=function()
                    if not current(host,ctx) or ctx.dialog~=confirm then return end
                    local scope=host.settings:get_auth_scope();local cleared=scope and ctx.journal:finish(scope,record)
                    M.cancel(host);host:showInfo(cleared and _('Pending upload record cleared.') or _('Could not clear the pending upload record.'))
                end}
            ctx.dialog=confirm;UI:show(confirm)
        end}},
    }}
    ctx.dialog=dialog;UI:show(dialog)
end
local function start(host,ctx,input)
    if not current(host,ctx) then M.cancel(host);return false end
    if not host:isNetworkConnected() then M.cancel(host);host:showOffline(_('Upload local book'));return false end
    local selected=Access.capture(host.settings)
    if not selected or selected.renewal_pending then M.cancel(host);message(host,'login');return false end
    local record=ctx.journal:begin(selected.scope,input.path,input.size)
    if not record then M.cancel(host);message(host,'unconfirmed');return false end
    ctx.record=record;ctx.selected=selected
    host:showBusy(_('Uploading book…\nCancelling may leave the result unconfirmed.'),function()
        if current(host,ctx) then M.cancel(host);message(host,'unconfirmed') end
    end);ctx.busy=host.busy_message
    if not host.personal_upload_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=Model.MAX_RESULT} end)
        if not ok then M.cancel(host);message(host,'unconfirmed');return false end
        host.personal_upload_worker=worker
    end
    local function guard()
        return current(host,ctx) and Access.matches(host.settings,selected) and ctx.journal:owns(selected.scope,record)
    end
    local ok,started=pcall(host.personal_upload_worker.start,host.personal_upload_worker,
        function() return Model.run(host.client,host.settings,selected,input,ctx.journal,record,guard) end,function(result)
            if not guard() then if host._personal_upload_ui==ctx then M.cancel(host) end;return end
            if confirmed(result) then
                local saved,accepted=pcall(host.library_db.cacheShelf,host.library_db,result.snapshot.books,result.snapshot.archive)
                local finished=saved and accepted and ctx.journal:finish(selected.scope,record)
                if finished then host:applyShelfSnapshot(result.snapshot.books,result.snapshot.archive) end
                M.cancel(host);host:showInfo(finished and _('Book uploaded and verified in the cloud bookshelf.')
                    or _('The uploaded book was found, but the local confirmation could not be saved. Check the pending record.'))
                return
            end
            local unsent=type(result)=='table' and result.put_attempted==false and result.notify_attempted==false
            local finished=unsent and ctx.journal:finish(selected.scope,record)
            local kind=finished and result.kind or 'unconfirmed'
            M.cancel(host);message(host,kind)
        end)
    if not ok or not started then M.cancel(host);message(host,'unconfirmed');return false end
    return true
end
function M.choose(host,ctx,path)
    if not current(host,ctx) then return end
    local captured,input=pcall(Model.capture,path)
    if not captured or not input then M.cancel(host);host:showInfo(_('Choose an EPUB, PDF, MOBI, TXT or AZW3 file up to 8 MiB.'));return end
    local dialog
    dialog=Confirm:new{text=T(_('Upload “%1” to your cloud bookshelf?\n\nThe original file remains on this device.'),input.name),
        ok_text=_('Upload'),cancel_callback=function() if current(host,ctx) then M.cancel(host) end end,
        ok_callback=function()
            if not current(host,ctx) or ctx.dialog~=dialog then return end
            ctx.dialog=nil;UI:close(dialog);start(host,ctx,input)
        end}
    ctx.dialog=dialog;UI:show(dialog)
end
function M.open(host)
    M.cancel(host)
    if not host.library_db or not host.library_db:accountKey() then message(host,'login');return false end
    local scope=host.settings:get_auth_scope()
    if not scope or not host.settings:auth_scope_matches(scope) then message(host,'login');return false end
    local ctx={owner=owner(host),journal=Journal:new(host.settings,host.client)};host._personal_upload_ui=ctx
    local record,reason=ctx.journal:read(scope)
    if not record then M.cancel(host);message(host,reason=='session_changed' and 'login' or 'unconfirmed');return false end
    if record.phase=='pending' then pending(host,ctx,record);return true end
    if not Access.capture(host.settings) then M.cancel(host);message(host,'login');return false end
    local root=host.ui and host.ui.file_chooser and host.ui.file_chooser.path
        or G_reader_settings and G_reader_settings:readSetting('home_dir') or '/'
    local chooser
    chooser=require('ui/widget/pathchooser'):new{path=root,select_directory=false,select_file=true,file_filter=Model.accepts_name,
        title=_('Choose a book to upload'),onConfirm=function(path)
            if not current(host,ctx) or ctx.chooser~=chooser then return end
            ctx.chooser=nil;UI:nextTick(function() if current(host,ctx) then M.choose(host,ctx,path) end end)
        end}
    local close=chooser.onCloseWidget
    chooser.onCloseWidget=function(instance,...)
        if current(host,ctx) and ctx.chooser==instance then ctx.chooser=nil;M.cancel(host) end
        if close then return close(instance,...) end
    end
    ctx.chooser=chooser;UI:show(chooser);return true
end
return M
