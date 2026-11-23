-- This reminder covers only the current reader session. KOReader remains
-- responsible for saving the local page, and no position is sent here.
local UI=require('ui/uimanager')
local Context=require('weread.lib.source_context')
local Path=require('weread.lib.native_direct_path')
local Contract=require('weread.lib.native_position_contract')
local _=require('weread.lib.plugin_util').tr
local M={}

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
    if ctx.dialog or ctx.task then dismiss(ctx) end
    if ctx.pending and not Context.same_location(ctx.pending,now) then ctx.pending=nil end
    if ctx.offline or not online(host) then
        if not ctx.offline then ctx.offline=true end
        ctx.dirty=not Context.same_location(ctx.baseline,now)
    else
        ctx.baseline=now
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
    if ctx then dismiss(ctx) end
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
    if type(settings)~='table' or settings.pull_on_open~=true then ctx.pending=nil;return end
    if changed then ctx.pending=now end
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
            local allowed=valid();ctx.dialog=nil;ctx.pending=nil;UI:close(dialog)
            if allowed and action then require('weread.ui.native_direct_navigation').open_position(host,action) end
        end
        dialog=require('ui/widget/buttondialog'):new{
            title=_('You changed pages offline. Your local page is kept. Compare with the cloud or sync this page?'),
            buttons={{{text=_('Compare cloud position'),id='reconnect_cloud',callback=function() choose('cloud') end}},
                {{text=_('Sync this page'),id='reconnect_upload',callback=function() choose('upload') end}},
                {{text=_('Later'),id='reconnect_later',callback=function() choose() end}}},
            close_callback=function() if ctx.dialog==dialog then ctx.dialog=nil;ctx.pending=nil end end,
        }
        ctx.dialog=dialog;UI:show(dialog)
    end
    UI:scheduleIn(.2,ctx.task)
end
return M
