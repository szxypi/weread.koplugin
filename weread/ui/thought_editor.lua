-- Native personal-thought editor. Local drafts survive cancellation; a
-- pending dispatch is recovered only by GET, never by replaying its body.
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Contract=require('weread.lib.thought_edit_contract')
local Store=require('weread.lib.thought_edit_store')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.can_create(row)
    if type(row)=='table' and row.selection then return require('weread.lib.selection_reference').valid(row,row.source and row.source.book_id) end
    return type(row)=='table' and require('weread.lib.my_mark_target').can_locate(row)
        and type(row.markText)=='string' and #row.markText<=4096
end
function M.can_edit(row) return type(row)=='table' and Contract.key(row.reviewId) and (row.isPrivate==0 or row.isPrivate==1) end
local function store(host) return Store:new(host.library_db,host.client) end
local function alive(ctx) return ctx.owner.editor==ctx and ctx.current(ctx.host,ctx.owner) end
local function local_current(ctx)
    return ctx.owner.account~=nil and ctx.owner.account==ctx.host.library_db:accountKey()
        and ctx.host.settings:auth_scope_matches(ctx.owner.scope)
end
local function save(ctx,text)
    if ctx.operation=='delete' then return true end
    if not local_current(ctx) or not Contract.valid_content(text) then return false end
    local draft=ctx.journal:save_draft(ctx.owner.id,ctx.operation,ctx.reference_id,ctx.base_hash,text,ctx.draft and ctx.draft.token or false)
    if not draft then return false end
    ctx.draft,ctx.text=draft,text;return true
end
local function detach(ctx)
    if ctx.owner.editor~=ctx then return end
    ctx.owner.editor=nil;ctx.dialog=nil
    ctx.service:cancel()
    if ctx.restore_worker then ctx.restore_worker:cancel() end
    if ctx.source_worker then ctx.source_worker:cancel() end
    if ctx.source_lease then ctx.source_lease:release();ctx.source_lease=nil end
end
function M.cancel(_host,owner)
    local ctx=owner.editor;if not ctx then return end
    if ctx.input and ctx.dialog==ctx.input then
        local text=ctx.input:getInputText()
        if Contract.valid_content(text) and not save(ctx,text) and local_current(ctx) then
            ctx.host:showInfo(_('Could not save this draft. It may have changed elsewhere, or storage is full.'))
        end
    end
    local dialog=ctx.dialog;detach(ctx)
    if Popup.current(owner.menu,dialog) then Popup.close(owner.menu) end
end
local function show(ctx,dialog,input)
    ctx.dialog=nil;ctx.input=nil
    Popup.show(ctx.owner.menu,dialog,function(widget)
        ctx.dialog=widget;ctx.input=input and widget or nil
        if input then ctx.host:showInputDialog(widget) else UI:show(widget) end
    end)
    local closed=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if ctx.dialog==instance and ctx.owner.editor==ctx then
            if ctx.input==instance then
                local text=instance:getInputText()
                if Contract.valid_content(text) and not save(ctx,text) and local_current(ctx) then
                    ctx.host:showInfo(_('Could not save this draft. It may have changed elsewhere, or storage is full.'))
                end
            end
            detach(ctx)
        end
        if closed then return closed(instance,...) end
    end
end
local function done(ctx)
    local dialog=ctx.dialog;detach(ctx)
    if Popup.current(ctx.owner.menu,dialog) then Popup.close(ctx.owner.menu) end
end
local function message(ctx,key)
    if alive(ctx) then done(ctx);ctx.host:showInfo(_(key)) end
end
local function failure(ctx,reason)
    local key=reason=='source_login' and 'Log in again to verify the selected text. Your local draft is kept.'
        or (reason=='pending' or reason=='unconfirmed') and 'A thought change needs checking. Use Check last thought change before submitting again.'
        or (reason=='login' or reason=='native_expired') and 'Authorize or renew E-Ink login in settings, then try again.'
        or 'The thought or quoted highlight changed, or could not be checked. Your local draft is kept. Refresh and try again.'
    message(ctx,key)
end
local function viewer(ctx,title,text,buttons)
    show(ctx,require('weread.ui.thought_text').viewer{title=_(title),text=_(text),buttons_table=buttons,add_default_buttons=true})
end
local function busy(ctx,label)
    viewer(ctx,label,'Closing this window stops the check. Any submitted change will only be checked, never sent again.')
end
local function reload(ctx)
    local snapshot=ctx.cache:read(ctx.owner.id)
    if ctx.owner.thoughts then ctx.owner.value=snapshot or ctx.owner.value end
    local display=package.loaded['weread.ui.personal_marks']
    if snapshot and display and type(display.thoughts_changed)=='function' then display.thoughts_changed(ctx.host,snapshot) end
    if ctx.redraw then ctx.redraw(ctx.host,ctx.owner) end
end
local function submit(ctx)
    if not alive(ctx) then return end
    if not ctx.host:isNetworkOnline() then ctx.host:showOffline(_('Thought'));return end
    if ctx.operation~='delete' and not save(ctx,ctx.input:getInputText()) then
        ctx.host:showInfo(_('Enter thought text, then save a local draft before submitting. Draft storage may be full.'));return
    end
    busy(ctx,'Checking this thought…')
    local input={book_id=ctx.owner.id,operation=ctx.operation,reference=ctx.reference,content=ctx.text,draft=ctx.draft,source_file=ctx.source_file}
    local started,reason=ctx.service:prepare(input,function() return alive(ctx) end,function(plan,why)
        if not alive(ctx) then return end
        if not plan then failure(ctx,why);return end
        local title=ctx.operation=='create' and 'Create private thought?' or ctx.operation=='edit' and 'Save changes to this thought?' or 'Delete this thought?'
        local privacy=ctx.operation=='create' or ctx.reference.isPrivate==1
        local text=ctx.operation=='delete' and _('This deletes only the selected thought from WeRead. This cannot be undone.')
            or privacy and _('This thought is private. Only the text shown below will be saved.')
            or _('This thought is public. Editing keeps it public. Only the text shown below will be saved.')
        if ctx.operation~='delete' then
            if ctx.reference.selection then text=text..'\n\n'.._('Quoted text')..'\n'..ctx.reference.markText..'\n\n'.._('Thought') end
            text=text..'\n\n'..ctx.text
        end
        local dialog
        dialog=require('weread.ui.thought_text').viewer{title=_(title),text=text,add_default_buttons=true,
            buttons_table={{{id='confirm_thought_change',text=_(ctx.operation=='delete' and 'Delete this thought' or 'Save thought'),callback=function()
                if not alive(ctx) or not Popup.current(ctx.owner.menu,dialog) then return end
                busy(ctx,'Saving this thought…')
                local sent,err=ctx.service:commit(plan,function(result,finished)
                    if not alive(ctx) then return end
                    if finished and result.kind=='confirmed' then
                        reload(ctx);message(ctx,'Cloud thought change verified.')
                    elseif finished and result.kind=='noop' then message(ctx,'Thought unchanged. Your local draft is kept.')
                    elseif finished then failure(ctx,result.kind)
                    else failure(ctx,'unconfirmed') end
                end)
                if not sent then failure(ctx,err) end
            end}}}}
        show(ctx,dialog)
    end)
    if not started then failure(ctx,reason) end
end
local function new_context(host,owner,current,redraw)
    require('weread.ui.mark_editor').cancel(host,owner)
    M.cancel(host,owner)
    local journal=store(host)
    local cache=require('weread.lib.my_cloud_marks_store'):new(host.library_db,host.client,'thoughts')
    local ctx={host=host,owner=owner,current=current,redraw=redraw,journal=journal,cache=cache}
    ctx.service=require('weread.lib.thought_edit_service'):new{settings=host.settings,client=host.client,scheduler=UI,journal=journal,cache=cache}
    owner.editor=ctx;return ctx
end
function M.start(host,owner,operation,reference,current,redraw,restore)
    if not current(host,owner) or operation=='create' and not M.can_create(reference)
        or operation~='create' and (operation~='edit' and operation~='delete' or not M.can_edit(reference))
        or not require('weread.lib.my_cloud_marks').id(owner.id) and operation~='create' and reference.isPrivate~=1 then return false end
    local ctx=new_context(host,owner,current,redraw)
    ctx.operation,ctx.reference=operation,reference
    if reference.selection then ctx.source_file=owner.source_file or host.ui and host.ui.document and host.ui.document.file end
    ctx.reference_id=operation=='create' and reference.bookmarkId or reference.reviewId
    ctx.base_hash=Contract.reference_hash(operation,reference)
    local function open_editor()
    if not alive(ctx) then return end
    if operation=='delete' then submit(ctx);return end
    local draft=restore or ctx.journal:draft(Store.draft_key(owner.id,operation,ctx.reference_id))
    if draft and draft.base_hash~=ctx.base_hash then
        message(ctx,'This draft refers to an older cloud version. View or delete it in Local thought drafts; refresh before editing again.');return
    end
    ctx.draft=draft
    local input=draft and draft.content or operation=='edit' and reference.content or ''
    local dialog
    dialog=require('weread.ui.thought_text').input{title=_(operation=='create' and 'Write private thought' or 'Edit this thought'),input=input,
        input_type='text',allow_newline=true,use_available_height=true,
        buttons={{{id='save_thought_draft',text=_('Save local draft'),callback=function()
            if alive(ctx) and Popup.current(owner.menu,dialog) then
                if save(ctx,dialog:getInputText()) then message(ctx,'Thought draft saved on this device.')
                else host:showInfo(_('Could not save this draft. It may have changed elsewhere, or storage is full.')) end
            end
        end},{id='submit_thought',text=_('Continue'),callback=function()
            if alive(ctx) and Popup.current(owner.menu,dialog) then submit(ctx) end
        end}}}}
    show(ctx,dialog,true)
    end
    if reference.selection and require('weread.lib.native_direct_path').contains(host.settings,ctx.source_file) then
        local cache=require('weread.lib.native_direct_cache')
        local vid=type(owner.scope)=='table' and owner.scope.vid
        local opened,lease=pcall(cache.acquire,host.settings,vid,owner.id)
        if not opened then lease=nil end
        if not lease then message(ctx,'This chapter is being updated or cleaned. Try opening the thought again.');return false end
        ctx.source_lease=lease
        viewer(ctx,'Checking selected text…','Closing this window stops the check.')
        local worker_ok,worker=pcall(function()
            return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client}
        end)
        if not worker_ok or not worker then message(ctx,'The selected source is unavailable or changed. Your local draft is kept.');return false end
        ctx.source_worker=worker
        local started_ok,started=pcall(ctx.source_worker.start,ctx.source_worker,function()
            local entry=cache.identify(host.settings,vid,ctx.source_file,function()
                return local_current(ctx) and lease:owns()
            end)
            return {entry=entry}
        end,function(result)
            if not alive(ctx) or not local_current(ctx) then
                if owner.editor==ctx then M.cancel(host,owner) end;return
            end
            local entry=type(result)=='table' and result.entry
            if type(entry)~='table' or not lease:owns() or entry.book_id~=owner.id
                or entry.chapter_uid~=reference.source.chapter_uid or entry.source_sha256~=reference.source.raw_sha256
                or owner.direct_entry and entry.file_id~=owner.direct_entry.file_id then
                message(ctx,'The selected source is unavailable or changed. Your local draft is kept.');return
            end
            open_editor()
        end)
        if not started_ok or not started then message(ctx,'The selected source is unavailable or changed. Your local draft is kept.');return false end
        return true
    end
    open_editor();return owner.editor==ctx
end
function M.check(host,owner,current,redraw)
    if not current(host,owner) then return false end
    local ctx=new_context(host,owner,current,redraw)
    if not host:isNetworkOnline() then done(ctx);host:showOffline(_('Thought'));return false end
    busy(ctx,'Checking last thought change…')
    local started,reason=ctx.service:prepare({},function() return alive(ctx) end,function(plan,why)
        if not alive(ctx) then return end
        if not plan then
            if why=='no_pending' then message(ctx,'No thought change needs checking.') else failure(ctx,why) end;return
        end
        if plan.unsent or plan.confirmed then
            local ok=ctx.service:resolve(plan)
            if ok then reload(ctx);message(ctx,plan.unsent and 'The unsent change was cancelled. Your local draft is kept.' or 'Cloud thought change verified.')
            else failure(ctx,'unconfirmed') end
            return
        end
        local dialog
        dialog=require('weread.ui.thought_text').viewer{title=_('Thought change not confirmed'),
            text=_('The cloud does not match the expected change. No request was sent again. You can keep checking, or accept the current cloud state. Accepting does not undo a change; a delayed change may still appear. Check your thoughts before creating another copy.'),
            add_default_buttons=true,buttons_table={{{id='accept_thought_state',text=_('Accept current thought state'),callback=function()
                if not alive(ctx) or not Popup.current(owner.menu,dialog) then return end
                local confirm
                confirm=require('ui/widget/confirmbox'):new{text=_('Accept the current cloud state and unlock future thought changes? Your draft is kept, and this does not resend or undo anything.'),
                    ok_text=_('Accept current thought state'),ok_callback=function()
                        if not alive(ctx) or not Popup.current(owner.menu,confirm) then return end
                        local ok=ctx.service:resolve(plan,true)
                        if ok then reload(ctx);message(ctx,'Current cloud thought state accepted. Review it before making another change.') else failure(ctx,'unconfirmed') end
                    end}
                show(ctx,confirm)
            end}}}}
        show(ctx,dialog)
    end,true)
    if not started then
        if reason=='no_pending' then message(ctx,'No thought change needs checking.') else failure(ctx,reason) end
    end
    return started
end
-- Resume only the exact draft revision shown to the user. Cached references
-- must still match its original hash; selection drafts re-check source bytes.
function M.resume(host,owner,key,version,current,redraw)
    if not current(host,owner) then return false end
    local ctx=new_context(host,owner,current,redraw)
    local draft,why=ctx.journal:draft(key)
    if why or not draft or draft.token~=version or draft.book_id~=owner.id then
        message(ctx,'This draft changed or is unavailable. Open local thought drafts again.');return false
    end
    local selection=draft.operation=='create' and require('weread.lib.selection_reference').parse(draft.reference_id)
    if not selection and ((draft.operation=='edit')~=owner.thoughts) then
        message(ctx,'The original thought or highlight is unavailable. Refresh its notes and try again.');return false
    end
    local reference
    for _i,row in ipairs(owner.value and (owner.thoughts and owner.value.reviews or owner.value.updated) or {}) do
        if (owner.thoughts and row.reviewId or row.bookmarkId)==draft.reference_id then reference=row end
    end
    if reference and Contract.reference_hash(draft.operation,reference)==draft.base_hash then
        return M.start(host,owner,draft.operation,reference,current,redraw,draft)
    end
    if not selection then
        message(ctx,'The original thought or highlight is unavailable. Refresh its notes and try again.');return false
    end
    busy(ctx,'Checking selected text…')
    ctx.restore_worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client}
    local source_file=host.ui and host.ui.document and host.ui.document.file
    local offline=owner.direct and not host:isNetworkOnline()
    local started=ctx.restore_worker:start(function()
        if owner.direct then
            local NativeAccess=require('weread.lib.native_read_access');local Source=require('weread.lib.source_currentness')
            local function current_source() return host.settings:auth_scope_matches(owner.scope)
                and NativeAccess.matches(host.settings,owner.native) and Source.matches(host.settings,owner.web) end
            local refs=require('weread.lib.native_direct_reference')
            local row
            if offline then
                row=refs.restore_cached(host.settings,host.library_db,owner.direct_entry,source_file,
                    draft.reference_id,owner.native,owner.web,current_source)
            else
                row=refs.restore(host.client,host.settings,owner.direct_entry,source_file,
                    draft.reference_id,owner.native,owner.web,current_source,host.library_db)
            end
            return {reference=row}
        end
        local book=host.settings:get_book(owner.id)
        if not book then return {} end
        book.chapters=host.library_db:getChapters(owner.id)
        local row=require('weread.lib.selection_reference').restore(book,source_file,draft.reference_id)
        return {reference=row}
    end,function(result)
        if not alive(ctx) then return end
        local latest,error_=ctx.journal:draft(draft.draft_key)
        if error_ or not latest or latest.token~=draft.token or latest.book_id~=owner.id then
            message(ctx,'This draft changed or is unavailable. Open local thought drafts again.');return
        end
        local row=type(result)=='table' and result.reference
        if row and Contract.reference_hash('create',row)==latest.base_hash then
            M.start(host,owner,'create',row,current,redraw,latest)
        else message(ctx,'The selected source is unavailable or changed. Your local draft is kept.') end
    end)
    if not started then message(ctx,'The selected source is unavailable or changed. Your local draft is kept.') end
    return started
end
local function cross_book(host,owner,current,draft,ctx)
    if not alive(ctx) or not current(host,owner) then return false end
    local notebook=host._notebook_owner
    local inherited=notebook and (notebook==owner or notebook.child==owner)
    local request={book_id=draft.book_id,key=draft.draft_key,token=draft.token,operation=draft.operation,
        selection=draft.operation=='create' and require('weread.lib.selection_reference').parse(draft.reference_id)~=nil}
    done(ctx)
    local opened=require('weread.ui.my_cloud_marks').show(host,draft.book_id,draft.operation=='edit' and 'thoughts' or nil,
        {resume_draft=request})
    if opened and inherited and host._notebook_owner==notebook then notebook.child=host._my_marks_owner end
    return opened
end
local function draft_book_label(host,id)
    local ok,book=pcall(function() return host.library_db.getBook and host.library_db:getBook(id) end)
    local title=ok and type(book)=='table' and book.title or nil
    if type(title)~='string' or title=='' or #title>4096 or title:find('[%z%c]') then
        return _('Book ID')..' '..id
    end
    local short=require('weread.lib.protocol').utf8_substr(title,20)
    return #short<#title and short..'…' or short
end
function M.drafts(host,owner,current,redraw)
    if not current(host,owner) then return false end
    local ctx=new_context(host,owner,current,redraw);local values=ctx.journal:drafts()
    if not values then message(ctx,'Could not load local thought drafts.');return false end
    if #values==0 then message(ctx,'No local thought drafts.');return true end
    local items={}
    for _i,draft in ipairs(values) do
        items[#items+1]={text=require('weread.lib.protocol').utf8_substr(draft.content:gsub('[%z%c]',' '),60),
            mandatory=draft.book_id~=owner.id and draft_book_label(host,draft.book_id) or nil,callback=function()
            if not alive(ctx) then return end
            local dialog
            local buttons={{{id='delete_thought_draft',text=_('Delete local draft'),callback=function()
                if not alive(ctx) or not Popup.current(owner.menu,dialog) then return end
                if ctx.journal:delete_draft(draft) then message(ctx,'Local thought draft deleted.') else message(ctx,'Could not load local thought drafts.') end
            end}}}
            -- The target list re-reads the draft and checks its exact source.
            local selection_draft=draft.operation=='create' and require('weread.lib.selection_reference').parse(draft.reference_id)
            if draft.book_id==owner.id and ((draft.operation=='edit')==owner.thoughts or selection_draft) then
                buttons[1][#buttons[1]+1]={id='resume_thought_draft',text=_('Resume draft'),callback=function()
                    if alive(ctx) and Popup.current(owner.menu,dialog) then
                        M.resume(host,owner,draft.draft_key,draft.token,current,redraw)
                    end
                end}
            else
                buttons[1][#buttons[1]+1]={id='resume_other_book_draft',text=_('Open book and resume draft'),callback=function()
                    if alive(ctx) and Popup.current(owner.menu,dialog) then cross_book(host,owner,current,draft,ctx) end
                end}
            end
            dialog=require('weread.ui.thought_text').viewer{title=_('Local thought draft'),text=draft.content,buttons_table=buttons,add_default_buttons=true}
            show(ctx,dialog)
        end}
    end
    show(ctx,require('weread.ui.thought_text').menu{title=_('Local thought drafts'),item_table=items,is_popout=true,is_borderless=false})
    return true
end
return M
