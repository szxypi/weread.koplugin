-- Native highlight confirmation and read-only recovery. Submitted work is
-- never replayed; source, account, reader and menu guards survive each step.
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Service=require('weread.lib.mark_edit_service')
local _=require('weread.lib.plugin_util').tr
local M={}
local function display(host,action,value)
    local module=package.loaded['weread.ui.personal_marks'];if module then module[action](host,value) end
end
local function alive(ctx) return ctx.owner.mark_editor==ctx and ctx.current(ctx.host,ctx.owner) end
function M.cancel(_host,owner)
    local ctx=owner.mark_editor;if not ctx then return end
    owner.mark_editor=nil;ctx.service:cancel()
    display(ctx.host,'resume')
    if Popup.current(owner.menu,ctx.dialog) then Popup.close(owner.menu) end
end
local function show(ctx,title,text,buttons)
    local dialog=require('weread.ui.thought_text').viewer{title=_(title),text=text,add_default_buttons=true,buttons_table=buttons}
    ctx.dialog=nil
    Popup.show(ctx.owner.menu,dialog,function(widget) ctx.dialog=widget;UI:show(widget) end)
    local closed=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if ctx.dialog==instance and ctx.owner.mark_editor==ctx then
            ctx.owner.mark_editor=nil;ctx.service:cancel();display(ctx.host,'resume')
        end
        if closed then return closed(instance,...) end
    end
    return dialog
end
local function message(ctx,key)
    if not alive(ctx) then return end
    M.cancel(ctx.host,ctx.owner);ctx.host:showInfo(_(key))
end
local function failure(ctx,reason)
    message(ctx,(reason=='pending' or reason=='unconfirmed') and 'A cloud mark change needs checking. Use Check last cloud mark change before submitting again.'
        or (reason=='login' or reason=='native_expired') and 'Authorize or renew E-Ink login in settings, then try again.'
        or reason=='source_login' and 'Log in again to verify the selected text.'
        or 'The cloud mark or its source changed, overlaps a saved note, or could not be checked. Refresh and try again.')
end
local function busy(ctx,title)
    show(ctx,title,_('Closing this window stops the check. Any submitted change will only be checked, never sent again.'))
end
local function reload(ctx,snapshot)
    if snapshot then display(ctx.host,'changed',snapshot.marks) end
    if not ctx.owner.thoughts and ctx.owner.value then ctx.owner.value=snapshot and snapshot.marks or ctx.cache:read(ctx.owner.id) or ctx.owner.value end
    if ctx.redraw then ctx.redraw(ctx.host,ctx.owner) end
end
local function context(host,owner,current,redraw)
    require('weread.ui.thought_editor').cancel(host,owner);M.cancel(host,owner)
    display(host,'pause')
    local journal=Service.new_journal(host.library_db,host.client);local cache=Service.new_cache(host.library_db,host.client)
    local ctx={host=host,owner=owner,current=current,redraw=redraw,journal=journal,cache=cache}
    ctx.service=Service:new{settings=host.settings,client=host.client,scheduler=UI,journal=journal,cache=cache}
    owner.mark_editor=ctx;return ctx
end
function M.start(host,owner,operation,reference,current,redraw,style,color)
    if not current(host,owner) or operation~='create' and operation~='delete' and operation~='style' and operation~='color'
        and operation~='bookmark_create' and operation~='bookmark_delete' then return false end
    local bookmark=operation=='bookmark_create' or operation=='bookmark_delete'
    if operation=='create' then
        style=require('weread.lib.mark_style').default(host.settings)
        color=require('weread.lib.mark_color').default(host.settings)
    end
    if not host:isNetworkOnline() then host:showOffline(_(bookmark and 'Bookmark' or 'Highlight'));return false end
    local ctx=context(host,owner,current,redraw)
    busy(ctx,bookmark and 'Checking bookmark position…' or 'Checking this highlight…')
    local started,reason=ctx.service:prepare({book_id=owner.id,operation=operation,reference=reference,style=style,color=color,
        source_file=owner.source_file or host.ui and host.ui.document and host.ui.document.file},function() return alive(ctx) end,function(plan,why)
        if not alive(ctx) then return end
        if not plan then failure(ctx,why);return end
        local title=operation=='bookmark_create' and 'Save this cloud bookmark?' or operation=='bookmark_delete' and 'Delete this cloud bookmark?'
            or operation=='create' and 'Save this highlight?' or operation=='style' and 'Change this highlight style?'
            or operation=='color' and 'Change this highlight color?' or 'Delete this highlight?'
        local text=_(operation=='create' and 'Save the quoted text as a WeRead highlight.' or
            'This deletes only the selected highlight from WeRead. Highlights linked to your thoughts cannot be deleted here.')
        if operation=='style' then text=_('Change the style while keeping its saved color setting and quoted text.')..'\n\n'.._(require('weread.lib.mark_style').labels[style]) end
        if operation=='color' then text=_('Change the color while keeping its saved style and quoted text.')..'\n\n'.._(require('weread.lib.mark_color').labels[color]) end
        if operation=='create' then text=text..'\n\n'.._(require('weread.lib.mark_style').labels[style])..' · '.._(require('weread.lib.mark_color').labels[color]) end
        if bookmark then text=_(operation=='bookmark_create' and 'Save this original-page position as a WeRead bookmark.'
            or 'Delete only this cloud bookmark. Your highlights and thoughts are kept.') end
        text=text..'\n\n'..(type(reference.markText)=='string' and reference.markText or '')
        local dialog
        dialog=show(ctx,title,text,{{{id='confirm_highlight_change',text=_(operation=='bookmark_create' and 'Save cloud bookmark'
            or operation=='bookmark_delete' and 'Delete cloud bookmark' or operation=='create' and 'Save highlight' or operation=='style' and 'Change highlight style'
            or operation=='color' and 'Change highlight color' or 'Delete highlight'),callback=function()
            if not alive(ctx) or not Popup.current(owner.menu,dialog) then return end
            busy(ctx,bookmark and 'Saving cloud bookmark…' or 'Saving this highlight…')
            local sent,err=ctx.service:commit(plan,function(result,finished)
                if not alive(ctx) then return end
                if finished and result.kind=='confirmed' then reload(ctx,result.snapshot);message(ctx,bookmark and 'Cloud bookmark change verified.' or 'Cloud highlight change verified.')
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
    if not host:isNetworkOnline() then host:showOffline(_('Cloud mark'));return false end
    local ctx=context(host,owner,current,redraw);busy(ctx,'Checking cloud mark change…')
    local started,reason=ctx.service:prepare({},function() return alive(ctx) end,function(plan,why)
        if not alive(ctx) then return end
        if not plan then message(ctx,why=='no_pending' and 'No cloud mark change needs checking.' or
            'The cloud mark or its source changed, overlaps a saved note, or could not be checked. Refresh and try again.');return end
        local dialog
        dialog=show(ctx,'Check last cloud mark change',_(plan.confirmed and 'The cloud mark matches the submitted change.' or
            'The cloud mark does not match a confirmed change. Keep the current cloud state without sending again?'),
            {{{id='resolve_highlight_change',text=_('Keep current cloud state'),callback=function()
                if not alive(ctx) or not Popup.current(owner.menu,dialog) then return end
                local finished,snapshot=ctx.service:resolve(plan,true)
                if finished then reload(ctx,snapshot);message(ctx,'Cloud mark check finished. No change was sent again.')
                else failure(ctx,'unconfirmed') end
            end}}})
    end,true)
    if not started then message(ctx,reason=='no_pending' and 'No cloud mark change needs checking.' or
        'A cloud mark change needs checking. Use Check last cloud mark change before submitting again.') end
    return started
end
return M
