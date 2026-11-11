-- Native highlight confirmation and read-only recovery. Submitted work is
-- never replayed; source, account, reader and menu guards survive each step.
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Service=require('weread.lib.mark_edit_service')
local _=require('weread.lib.plugin_util').tr
local M={}
local function alive(ctx) return ctx.owner.mark_editor==ctx and ctx.current(ctx.host,ctx.owner) end
function M.cancel(_host,owner)
    local ctx=owner.mark_editor;if not ctx then return end
    owner.mark_editor=nil;ctx.service:cancel()
    if Popup.current(owner.menu,ctx.dialog) then Popup.close(owner.menu) end
end
local function show(ctx,title,text,buttons)
    local dialog=require('weread.ui.thought_text').viewer{title=_(title),text=text,add_default_buttons=true,buttons_table=buttons}
    ctx.dialog=nil
    Popup.show(ctx.owner.menu,dialog,function(widget) ctx.dialog=widget;UI:show(widget) end)
    local closed=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if ctx.dialog==instance and ctx.owner.mark_editor==ctx then ctx.owner.mark_editor=nil;ctx.service:cancel() end
        if closed then return closed(instance,...) end
    end
    return dialog
end
local function message(ctx,key)
    if not alive(ctx) then return end
    M.cancel(ctx.host,ctx.owner);ctx.host:showInfo(_(key))
end
local function failure(ctx,reason)
    message(ctx,(reason=='pending' or reason=='unconfirmed') and 'A highlight change needs checking. Use Check last highlight change before submitting again.'
        or (reason=='login' or reason=='native_expired') and 'Authorize or renew E-Ink login in settings, then try again.'
        or reason=='source_login' and 'Log in again to verify the selected text.'
        or 'The highlight or its source changed, overlaps a saved note, or could not be checked. Refresh and try again.')
end
local function busy(ctx,title)
    show(ctx,title,_('Closing this window stops the check. Any submitted change will only be checked, never sent again.'))
end
local function reload(ctx,snapshot)
    if not ctx.owner.thoughts and ctx.owner.value then ctx.owner.value=snapshot and snapshot.marks or ctx.cache:read(ctx.owner.id) or ctx.owner.value end
    if ctx.redraw then ctx.redraw(ctx.host,ctx.owner) end
end
local function context(host,owner,current,redraw)
    require('weread.ui.thought_editor').cancel(host,owner);M.cancel(host,owner)
    local journal=Service.new_journal(host.library_db,host.client);local cache=Service.new_cache(host.library_db,host.client)
    local ctx={host=host,owner=owner,current=current,redraw=redraw,journal=journal,cache=cache}
    ctx.service=Service:new{settings=host.settings,client=host.client,scheduler=UI,journal=journal,cache=cache}
    owner.mark_editor=ctx;return ctx
end
function M.start(host,owner,operation,reference,current,redraw)
    if not current(host,owner) or operation~='create' and operation~='delete' then return false end
    if not host:isNetworkOnline() then host:showOffline(_('Highlight'));return false end
    local ctx=context(host,owner,current,redraw)
    busy(ctx,'Checking this highlight…')
    local started,reason=ctx.service:prepare({book_id=owner.id,operation=operation,reference=reference,
        source_file=owner.source_file or host.ui and host.ui.document and host.ui.document.file},function() return alive(ctx) end,function(plan,why)
        if not alive(ctx) then return end
        if not plan then failure(ctx,why);return end
        local title=operation=='create' and 'Save this highlight?' or 'Delete this highlight?'
        local text=_(operation=='create' and 'Save the quoted text as a WeRead highlight.' or
            'This deletes only the selected highlight from WeRead. Highlights linked to your thoughts cannot be deleted here.')
        text=text..'\n\n'..(type(reference.markText)=='string' and reference.markText or '')
        local dialog
        dialog=show(ctx,title,text,{{{id='confirm_highlight_change',text=_(operation=='create' and 'Save highlight' or 'Delete highlight'),callback=function()
            if not alive(ctx) or not Popup.current(owner.menu,dialog) then return end
            busy(ctx,'Saving this highlight…')
            local sent,err=ctx.service:commit(plan,function(result,finished)
                if not alive(ctx) then return end
                if finished and result.kind=='confirmed' then reload(ctx,result.snapshot);message(ctx,'Cloud highlight change verified.')
                else failure(ctx,finished and result.kind or 'unconfirmed') end
            end)
            if not sent then failure(ctx,err) end
        end}}})
    end)
    if not started then failure(ctx,reason) end
    return started
end
function M.check(host,owner,current,redraw)
    if not current(host,owner) then return false end
    if not host:isNetworkOnline() then host:showOffline(_('Highlight'));return false end
    local ctx=context(host,owner,current,redraw);busy(ctx,'Checking this highlight…')
    local started,reason=ctx.service:prepare({},function() return alive(ctx) end,function(plan,why)
        if not alive(ctx) then return end
        if not plan then message(ctx,why=='no_pending' and 'No highlight change needs checking.' or
            'The highlight or its source changed, overlaps a saved note, or could not be checked. Refresh and try again.');return end
        local dialog
        dialog=show(ctx,'Check last highlight change',_(plan.confirmed and 'The cloud highlight matches the submitted change.' or
            'The cloud highlight does not match a confirmed change. Keep the current cloud state without sending again?'),
            {{{id='resolve_highlight_change',text=_('Keep current cloud state'),callback=function()
                if not alive(ctx) or not Popup.current(owner.menu,dialog) then return end
                local finished,snapshot=ctx.service:resolve(plan,true)
                if finished then reload(ctx,snapshot);message(ctx,'Highlight check finished. No change was sent again.')
                else failure(ctx,'unconfirmed') end
            end}}})
    end,true)
    if not started then message(ctx,reason=='no_pending' and 'No highlight change needs checking.' or
        'A highlight change needs checking. Use Check last highlight change before submitting again.') end
    return started
end
return M
