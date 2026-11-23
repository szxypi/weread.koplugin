-- KOReader saves the local page; this account-bound reminder never grants
-- authority to send a cloud position.
local UI=require('ui/uimanager')
local Context=require('weread.lib.source_context')
local Path=require('weread.lib.native_direct_path')
local Contract=require('weread.lib.native_position_contract')
local _=require('weread.lib.plugin_util').tr
local M={}
local function same_entry(entry,record)
    return type(entry)=='table' and type(record)=='table' and record.file_id==entry.file_id
        and record.book_id==entry.book_id and record.chapter_uid==entry.chapter_uid
        and record.version==entry.book_version and record.source_sha256==entry.source_sha256
        and record.key==entry.key and record.copy==entry.copy
end

local function online(host)
    local method=host.isNetworkConnected or host.isNetworkOnline
    if type(method)~='function' then return false end
    local ok,value=pcall(method,host)
    return ok and value==true
end
local function location(ctx)
    return Context.location(ctx.document,ctx.reader.view and ctx.reader.view.view_mode or 'page')
end
local function same_reader(host,ctx)
    return host._native_direct_reconnect==ctx and host.ui==ctx.reader and ctx.reader.document==ctx.document
        and ctx.document.file==ctx.file and (host._reader_session_gen or 0)==ctx.session
end
local function current(host,ctx)
    if not same_reader(host,ctx)
        or not host.settings:auth_scope_matches(ctx.scope) or not host.library_db
        or host.library_db:accountKey()~=ctx.account then return false end
    return true
end
local function dismiss(ctx)
    if ctx.task then UI:unschedule(ctx.task);ctx.task=nil end
    if ctx.dialog then local dialog=ctx.dialog;ctx.dialog=nil;UI:close(dialog) end
end
local function warn(host)
    if host.showTransientInfo then
        host:showTransientInfo(_('Could not save the offline sync reminder. Your local reading page is kept.'),3)
    end
end
local function visible(host,ctx,point)
    local ok,value=pcall(function()
        if ctx.reader.view and ctx.reader.view.view_mode=='scroll' then
            local get_height=host.progress_sync and host.progress_sync.get_viewport_height
            local height=get_height and get_height() or ctx.reader.view.dimen and ctx.reader.view.dimen.h
            local geometry=require('weread.lib.reader_position')
            local frame=geometry.snapshot(ctx.document,'scroll',height)
            return geometry.contains_anchor(ctx.document,frame,point)
        end
        return ctx.document:isXPointerInCurrentPage(point)
    end)
    return ok and value==true
end
function M.checkpoint(host)
    local ctx=host._native_direct_reconnect
    if not ctx then return nil end
    local required=ctx.offline and ctx.dirty or ctx.pending_dirty
    if not required then return nil end
    local point=location(ctx)
    if not point or not ctx.entry or not current(host,ctx)
        or ctx.pending_dirty and not Context.same_location(ctx.pending,point) then return false end
    local identity=require('weread.lib.book_file_identity').read_document(ctx.document,ctx.entry.book_id)
    if identity.file_id~=ctx.entry.file_id or identity.book_id~=ctx.entry.book_id
        or identity.book_version~=ctx.entry.book_version then return false end
    local lease=require('weread.lib.native_direct_cache').acquire(host.settings,ctx.scope.vid,ctx.entry.book_id)
    if not lease then return false end
    local function guard() return lease:owns() and current(host,ctx) and Context.same_location(point,location(ctx)) end
    local ok,saved=pcall(require('weread.lib.native_direct_pending').save,host.library_db,host.settings,ctx.scope,
        ctx.entry,point.xpointer,guard)
    lease:release()
    if not ok then return false end
    if not saved then return false end
    ctx.record={file_id=ctx.entry.file_id,book_id=ctx.entry.book_id,chapter_uid=ctx.entry.chapter_uid,
        version=ctx.entry.book_version,source_sha256=ctx.entry.source_sha256,key=ctx.entry.key,
        copy=ctx.entry.copy,xpointer=point.xpointer}
    ctx.pending_dirty=false
    return true
end
function M.bind(host,entry,record)
    local ctx=host._native_direct_reconnect
    if not ctx or not current(host,ctx) then return end
    ctx.entry=entry
    if same_entry(entry,record) then ctx.record=record end
    if ctx.pending_dirty and M.checkpoint(host)==false then warn(host) end
    if ctx.record and online(host) and not ctx.offline then
        ctx.pending=location(ctx);M.connected(host)
    end
end
function M.synced(host,entry,point)
    local ctx=host._native_direct_reconnect
    if not ctx or not same_entry(entry,ctx.record) or not current(host,ctx)
        or not Context.same_location(point,location(ctx)) or not visible(host,ctx,ctx.record.xpointer) then return end
    local record=ctx.record
    local function guard() return current(host,ctx) and Context.same_location(point,location(ctx)) end
    if require('weread.lib.native_direct_pending').remove(host.library_db,host.settings,ctx.scope,entry,record,guard) then
        ctx.record=nil;ctx.dismissed=nil
    end
end
function M.cancel(host)
    local ctx=host._native_direct_reconnect
    if not ctx then return end
    host._native_direct_reconnect=nil;dismiss(ctx)
end
function M.ready(host)
    M.cancel(host)
    local reader=host.ui;local doc=reader and reader.document;local file=doc and doc.file
    local scope=host.settings:get_auth_scope();local db=host.library_db
    if not Path.contains(host.settings,file) or type(scope)~='table' or not db or not db:accountKey()
        or db:accountKey()~=Contract.account_key(scope.vid) or not host.settings:auth_scope_matches(scope) then return false end
    local ctx={reader=reader,document=doc,file=file,scope=scope,account=db:accountKey(),
        session=host._reader_session_gen or 0,offline=not online(host)}
    ctx.baseline=location(ctx)
    if not ctx.baseline then return false end
    host._native_direct_reconnect=ctx
    return true
end
function M.view_changed(host)
    local ctx=host._native_direct_reconnect
    if not ctx then return end
    -- Page events only update local, in-memory state. Recheck the account
    -- before showing a prompt or opening a position operation, not per page.
    if not same_reader(host,ctx) then M.cancel(host);return end
    local now=location(ctx)
    if not now then M.cancel(host);return end
    if ctx.pending and not Context.same_location(ctx.pending,now) then
        dismiss(ctx);ctx.pending=nil;if ctx.record then ctx.dismissed=true end
    end
    if ctx.offline or not online(host) then
        if not ctx.offline then ctx.offline=true end
        ctx.dirty=not Context.same_location(ctx.baseline,now)
    else
        ctx.baseline=now
        local config=host.settings:get('sync',{})
        if ctx.record and not ctx.dismissed and type(config)=='table' and config.pull_on_open==true then
            ctx.pending=now;M.connected(host)
        end
    end
end
function M.disconnected(host)
    local ctx=host._native_direct_reconnect
    if not ctx then return end
    if not current(host,ctx) then M.cancel(host);return end
    dismiss(ctx)
    if not ctx.offline then ctx.baseline=location(ctx);ctx.dirty=false end
    if not ctx.baseline then M.cancel(host);return end
    ctx.offline=true
end
function M.suspend(host)
    local ctx=host._native_direct_reconnect
    if ctx then
        if M.checkpoint(host)==false then warn(host) end
        dismiss(ctx)
    end
end
function M.connected(host)
    local ctx=host._native_direct_reconnect
    if not ctx then return end
    if not current(host,ctx) then M.cancel(host);return end
    if not online(host) or host._weread_suspended then return end
    local now=location(ctx)
    if not now then M.cancel(host);return end
    local changed=ctx.offline and ctx.dirty and not Context.same_location(ctx.baseline,now)
    ctx.offline=false;ctx.baseline=now;ctx.dirty=false
    local settings=host.settings:get('sync',{})
    if changed then ctx.pending=now;ctx.pending_dirty=true end
    if ctx.pending_dirty and ctx.entry and M.checkpoint(host)==false then warn(host) end
    if type(settings)~='table' or settings.pull_on_open~=true then
        if not ctx.pending_dirty then ctx.pending=nil end
        return
    end
    if not ctx.pending and ctx.record and not ctx.dismissed then ctx.pending=now end
    if not ctx.pending or not Context.same_location(ctx.pending,now) then ctx.pending=nil;return end
    if ctx.dialog or ctx.task then return end
    local snapshot=ctx.pending
    local function valid()
        local config=host.settings:get('sync',{})
        return current(host,ctx) and not host._weread_suspended and online(host)
            and type(config)=='table' and config.pull_on_open==true
            and Context.same_location(snapshot,location(ctx))
    end
    ctx.task=function()
        ctx.task=nil
        if not valid() or host.busy_message or host._native_direct_position then return end
        local dialog
        local function choose(action)
            if ctx.dialog~=dialog then return end
            local allowed=valid();ctx.dialog=nil;ctx.pending=nil;ctx.dismissed=true;UI:close(dialog)
            if allowed and action=='discard' and ctx.record and ctx.entry and not ctx.pending_dirty then
                local record,entry=ctx.record,ctx.entry
                local confirm
                local function close_confirm()
                    if ctx.dialog==confirm then ctx.dialog=nil;ctx.pending=nil;UI:close(confirm) end
                end
                local function cancel_confirm()
                    if ctx.dialog==confirm then ctx.dialog=nil;ctx.pending=nil end
                end
                confirm=require('ui/widget/confirmbox'):new{
                    text=_('Remove this offline position reminder? The local reading page and cloud position will not change.'),
                    ok_text=_('Remove reminder'),cancel_text=_('Keep reminder'),keep_dialog_open=true,
                    cancel_callback=cancel_confirm,
                    ok_callback=function()
                        if ctx.dialog~=confirm or ctx.record~=record or ctx.pending_dirty or not valid() then close_confirm();return end
                        local function guard()
                            return ctx.dialog==confirm and ctx.record==record and not ctx.pending_dirty and valid()
                        end
                        local called,removed=pcall(require('weread.lib.native_direct_pending').remove,
                            host.library_db,host.settings,ctx.scope,entry,record,guard)
                        close_confirm()
                        if called and removed then ctx.record=nil end
                        if host.showInfo then host:showInfo(_(called and removed and 'Offline reminder removed.'
                            or 'Could not remove the offline reminder. It was kept.')) end
                    end,
                }
                ctx.pending=snapshot;ctx.dialog=confirm;UI:show(confirm)
            elseif allowed and action=='restore' and ctx.record and ctx.entry then
                local identity=require('weread.lib.book_file_identity').read_document(ctx.document,ctx.entry.book_id)
                local ok,found=pcall(ctx.document.isXPointerInDocument,ctx.document,ctx.record.xpointer)
                if identity.file_id==ctx.entry.file_id and identity.book_id==ctx.entry.book_id
                    and identity.book_version==ctx.entry.book_version and ok and found then
                    local moved=require('weread.lib.reader_position').goto_xpointer(ctx.reader,ctx.record.xpointer)
                    if moved and current(host,ctx) and visible(host,ctx,ctx.record.xpointer) then
                        ctx.dismissed=nil;ctx.pending=location(ctx);M.connected(host);return
                    end
                end
                if host.showInfo then host:showInfo(_('Could not confirm the saved offline position. Please check the current page.')) end
            elseif allowed and action then
                require('weread.ui.native_direct_navigation').open_position(host,action)
            end
        end
        local restore=ctx.record and not ctx.pending_dirty and not visible(host,ctx,ctx.record.xpointer)
        local buttons=restore and {{{text=_('Open offline position'),id='reconnect_restore',callback=function() choose('restore') end}}}
            or {{{text=_('Compare cloud position'),id='reconnect_cloud',callback=function() choose('cloud') end}},
                {{text=_('Sync this page'),id='reconnect_upload',callback=function() choose('upload') end}}}
        if ctx.record and not ctx.pending_dirty then
            buttons[#buttons+1]={{text=_('Remove offline reminder'),id='reconnect_discard',callback=function() choose('discard') end}}
        end
        buttons[#buttons+1]={{text=_('Later'),id='reconnect_later',callback=function() choose() end}}
        dialog=require('ui/widget/buttondialog'):new{
            title=restore and _('This chapter has a saved offline position. Open that position?')
                or _('You changed pages offline. Your local page is kept. Compare with the cloud or sync this page?'),
            buttons=buttons,
            close_callback=function() if ctx.dialog==dialog then ctx.dialog=nil;ctx.pending=nil;ctx.dismissed=true end end,
        }
        ctx.dialog=dialog;UI:show(dialog)
    end
    UI:scheduleIn(.2,ctx.task)
end
return M
