-- Reader-owned selection action. Bounded native context capture cooperates
-- with the UI; source parsing/hashing and all HTTP stay in child processes.
local UI=require('ui/uimanager')
local Context=require('weread.lib.source_context')
local Reference=require('weread.lib.selection_reference')
local Editor=require('weread.ui.thought_editor')
local Popup=require('weread.ui.shelf_popup')
local Marks=require('weread.lib.my_cloud_marks')
local _=require('weread.lib.plugin_util').tr
local M={KEY='04_weread_private_thought'}
local function current(host,owner)
    return host._selection_thought_owner==owner and not owner.menu._shelf_closed
        and owner.document==(host.ui and host.ui.document) and owner.document.file==owner.source_file
        and owner.account~=nil and owner.account==host.library_db:accountKey() and owner.session==host._reader_session_gen
        and owner.epoch==(host.discovery_epoch or 0) and host.settings:auth_scope_matches(owner.scope)
        and (host._translation_mode==nil or host._translation_mode=='original')
        and Context.same_location(owner.location,Context.location(owner.document,owner.mode))
end
local function stop(host,owner)
    Editor.cancel(host,owner)
    if owner.task then UI:unschedule(owner.task);owner.task=nil end
    if owner.worker then owner.worker:cancel() end
end
function M.cancel(host)
    local owner=host._selection_thought_owner;host._selection_thought_owner=nil
    if not owner then return end
    stop(host,owner);owner.menu._shelf_closed=true;Popup.close(owner.menu);UI:close(owner.menu)
end
function M.view_changed(host)
    local owner=host._selection_thought_owner
    if owner and not current(host,owner) then owner.error='view_changed';M.cancel(host) end
end
local render
render=function(host,owner)
    if not current(host,owner) then return end
    Popup.redraw(owner.menu,function()
    if not current(host,owner) then return end
    local items={}
    if owner.reference then
        items[#items+1]={text=_('Quoted text'),callback=function()
            if current(host,owner) then Popup.show(owner.menu,require('ui/widget/textviewer'):new{
                title=_('Quoted text'),text=owner.reference.markText,add_default_buttons=true}) end
        end}
        items[#items+1]={text=_('Write private thought'),callback=function()
            if current(host,owner) then Editor.start(host,owner,'create',owner.reference,current,render) end
        end}
    else items[#items+1]={text=_('Checking selected text…'),select_enabled=false} end
    items[#items+1]={text=_('Local thought drafts'),callback=function()
        if current(host,owner) then Editor.drafts(host,owner,current,render) end
    end}
    items[#items+1]={text=_('Check last thought change'),callback=function()
        if current(host,owner) then Editor.check(host,owner,current,render) end
    end}
    owner.menu:switchItemTable(nil,items)
    end)
end
function M.open(host,selection)
    M.cancel(host)
    local document=host.ui and host.ui.document;local id=host:detectWeReadBook()
    if not document or not Marks.id(id) or type(selection)~='table' or type(selection.text)~='string'
        or #selection.text==0 or type(selection.pos0)~='string' or type(selection.pos1)~='string'
        or host._translation_mode and host._translation_mode~='original' then return false end
    if #selection.text>4096 then host:showInfo(_('Select less text to write a WeRead thought.'));return false end
    local mode=host.ui.view and host.ui.view.view_mode or 'page'
    local owner={id=id,document=document,source_file=document.file,mode=mode,location=Context.location(document,mode),
        account=host.library_db:accountKey(),scope=host.settings:get_auth_scope(),session=host._reader_session_gen,
        epoch=host.discovery_epoch or 0,thoughts=false}
    if not owner.location or not owner.account then return false end
    local menu=host:showList(_('Write private thought'),{{text=_('Checking selected text…'),select_enabled=false}})
    if not menu then return false end
    owner.menu=menu;host._selection_thought_owner=owner
    local closed=menu.onCloseWidget
    menu.onCloseWidget=function(instance,...)
        instance._shelf_closed=true;Popup.close(instance);stop(host,owner)
        if host._selection_thought_owner==owner then host._selection_thought_owner=nil end
        if closed then return closed(instance,...) end
    end
    local function unavailable(reason)
        if not current(host,owner) then return end
        owner.error=reason or owner.error or 'selection_unavailable'
        M.cancel(host);host:showInfo(_('This selection could not be matched to the original source. Try another passage or download this chapter again.'))
    end
    owner.thread=coroutine.create(function()
        local inputs={text=selection.text,chapters=host.library_db:getChapters(id)}
        for _i,pair in ipairs({{'first',selection.pos0},{'last',selection.pos1}}) do
            local location={xpointer=document:getNormalizedXPointer(pair[2]),page=owner.location.page,pos=owner.location.pos,view_mode=mode}
            if not location.xpointer or not location.xpointer:find('/text()',1,true) then return nil end
            inputs[pair[1]]=Context.capture(document,id,location,{is_current=function() return current(host,owner) end,
                yield=function() coroutine.yield() end})
            if inputs[pair[1]].error then owner.error=inputs[pair[1]].error;return nil end
        end
        return inputs
    end)
    local advance
    advance=function()
        owner.task=nil
        if not current(host,owner) then
            owner.error='session_changed'
            if host._selection_thought_owner==owner then M.cancel(host) end
            return
        end
        local ok,input=coroutine.resume(owner.thread)
        if not ok then unavailable();return end
        if coroutine.status(owner.thread)~='dead' then owner.task=advance;UI:scheduleIn(.1,advance);return end
        owner.thread=nil
        if not input then unavailable();return end
        owner.worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client}
        local started=owner.worker:start(function()
            local row,reason=Reference.capture_native(input);return {reference=row,reason=reason}
        end,function(result)
            if not current(host,owner) then
                owner.error='session_changed'
                if host._selection_thought_owner==owner then M.cancel(host) end
                return
            end
            local row=type(result)=='table' and result.reference
            if not row or not Reference.valid(row,id) then unavailable(type(result)=='table' and result.reason);return end
            owner.reference=row;render(host,owner)
        end)
        if not started then unavailable() end
    end
    owner.task=advance;UI:scheduleIn(.1,advance);return true
end
function M.detach(host)
    M.cancel(host)
    local hook=host._selection_thought_hook;host._selection_thought_hook=nil
    if hook and hook.target._highlight_buttons and hook.target._highlight_buttons[M.KEY]==hook.factory then
        hook.target:removeFromHighlightDialog(M.KEY)
    end
end
function M.attach(host)
    M.detach(host)
    local highlight=host.ui and host.ui.highlight
    if not highlight or type(highlight.addToHighlightDialog)~='function' or type(highlight.removeFromHighlightDialog)~='function' then return false end
    local function factory(this)
        return {id='weread_selection_thought',text=_('Write private thought'),show_in_highlight_dialog_func=function()
            return Marks.id(host._current_weread_book_id)~=nil and this.selected_text and type(this.selected_text.text)=='string'
                and #this.selected_text.text>0 and this.select_mode~=true and host.library_db:accountKey()~=nil
                and (host._translation_mode==nil or host._translation_mode=='original')
        end,callback=function()
            local hook=host._selection_thought_hook
            if not hook or hook.factory~=factory or hook.target~=this or not host.ui or not host.ui.document then return end
            local selected=this.selected_text
            if not selected then return end
            local copy={text=selected.text,pos0=selected.pos0,pos1=selected.pos1};local document=host.ui.document
            local session,scope,account,epoch=host._reader_session_gen,host.settings:get_auth_scope(),host.library_db:accountKey(),host.discovery_epoch or 0
            this:onClose()
            -- Opening the menu for a saved native highlight has no hold_pos;
            -- ReaderHighlight:clear() then keeps selected_text. Consume only
            -- this transient copy so later source/progress work is not blocked.
            if this.selected_text==selected then this.selected_text=nil end
            UI:scheduleIn(.1,function()
                if host.ui.document==document and session==host._reader_session_gen and host.settings:auth_scope_matches(scope)
                    and account==host.library_db:accountKey() and epoch==(host.discovery_epoch or 0) then M.open(host,copy) end
            end)
        end}
    end
    highlight:addToHighlightDialog(M.KEY,factory);host._selection_thought_hook={target=highlight,factory=factory};return true
end
return M
