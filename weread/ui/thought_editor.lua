-- Native personal-thought editor. Local drafts survive cancellation; a
-- pending dispatch is recovered only by GET, never by replaying its body.
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Contract=require('weread.lib.thought_edit_contract')
local Store=require('weread.lib.thought_edit_store')
local NetworkLink=require('weread.lib.network_link')
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
local function cancel_drafts_read(ctx)
    local job=ctx.draft_job
    if not job then return end
    ctx.draft_job=nil
    UI:unschedule(job.notice)
    job.worker:cancel()
end
local function detach(ctx)
    if ctx.owner.editor~=ctx then return end
    ctx.owner.editor=nil;ctx.dialog=nil
    ctx.service:cancel()
    cancel_drafts_read(ctx)
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
    if ctx.operation~='delete' and not save(ctx,ctx.input:getInputText()) then
        ctx.host:showInfo(_('Enter thought text, then save a local draft before submitting. Draft storage may be full.'));return
    end
    if not NetworkLink.available(ctx.host) then
        if ctx.operation=='delete' then done(ctx);ctx.host:showOffline(_('Thought'))
        else ctx.host:showInfo(_('Thought draft saved on this device. Connect to Wi-Fi to continue.')) end
        return
    end
    busy(ctx,'Checking this thought…')
    local input={book_id=ctx.owner.id,operation=ctx.operation,reference=ctx.reference,content=ctx.text,draft=ctx.draft,source_file=ctx.source_file}
    local started,reason=ctx.service:prepare(input,function() return alive(ctx) end,function(plan,why)
        if not alive(ctx) then return end
        if not plan then failure(ctx,why);return end
        local title=ctx.operation=='create' and 'Create private thought?' or ctx.operation=='edit' and 'Save changes to this thought?' or 'Delete this thought?'
        local privacy=ctx.operation=='create' or ctx.reference.isPrivate==1
        local text=ctx.operation=='delete' and _(ctx.reference.attachment_state
                and 'This deletes the selected thought and its attachments from WeRead. This cannot be undone.'
                or 'This deletes only the selected thought from WeRead. This cannot be undone.')
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
                if not NetworkLink.available(ctx.host) then ctx.host:showOffline(_('Thought'));return end
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
function M.start(host,owner,operation,reference,current,redraw,restore,source)
    if not current(host,owner) or operation=='create' and not M.can_create(reference)
        or operation~='create' and (operation~='edit' and operation~='delete' or not M.can_edit(reference))
        or not require('weread.lib.my_cloud_marks').id(owner.id) and operation~='create' and reference.isPrivate~=1 then return false end
    local ctx=new_context(host,owner,current,redraw)
    ctx.operation,ctx.reference=operation,reference
    if reference.selection then
        ctx.source_file=source and source.path or owner.source_file or host.ui and host.ui.document and host.ui.document.file
    end
    ctx.reference_id=operation=='create' and reference.bookmarkId or reference.reviewId
    ctx.base_hash=Contract.reference_hash(operation,reference)
    local function open_editor()
    if not alive(ctx) then return end
    if operation=='delete' then submit(ctx);return end
    local draft,why
    if restore then
        draft,why=ctx.journal:draft(restore.draft_key)
        if why or not draft or draft.token~=restore.token or draft.book_id~=owner.id
            or draft.operation~=operation or draft.reference_id~=ctx.reference_id then
            message(ctx,'This draft changed or is unavailable. Open local thought drafts again.');return
        end
    else
        draft,why=ctx.journal:draft(Store.draft_key(owner.id,operation,ctx.reference_id))
        if why then message(ctx,'Could not load local thought drafts.');return end
    end
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
    local direct=reference.selection and require('weread.lib.native_direct_path').contains(host.settings,ctx.source_file)
    local expected_file=source and source.file_id or not source and owner.direct_entry and owner.direct_entry.file_id
    if source and source.file_id and (not direct or not Contract.hash(source.file_id)) then
        message(ctx,'The selected source is unavailable or changed. Your local draft is kept.');return false
    end
    if direct then
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
                or expected_file and entry.file_id~=expected_file then
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
    local record,read_error=ctx.journal:read()
    if not record then failure(ctx,read_error);return false end
    if record.phase=='idle' then message(ctx,'No thought change needs checking.');return false end
    if record.phase=='prepared' then
        -- The atomic phase check refuses cancellation once a worker has
        -- claimed dispatch. A prepared operation is safe to clear offline.
        if local_current(ctx) and ctx.journal:finish(record,'prepared') then
            message(ctx,'The unsent change was cancelled. Your local draft is kept.');return true
        end
        failure(ctx,'pending');return false
    end
    if not NetworkLink.available(host) then done(ctx);host:showOffline(_('Thought'));return false end
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
    local unavailable='The selected source is unavailable or changed. Your local draft is kept.'
    local ok,worker=pcall(function()
        return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client}
    end)
    if not ok or not worker then message(ctx,unavailable);return false end
    ctx.restore_worker=worker
    local source_file=host.ui and host.ui.document and host.ui.document.file
    local start_ok,started=pcall(worker.start,worker,function()
        local entry=owner.direct_entry
        if owner.direct and entry and entry.chapter_uid==selection.chapter_uid and entry.source_sha256==selection.raw_sha256 then
            local refs=require('weread.lib.native_direct_reference')
            local row,reason=refs.restore_cached(host.settings,host.library_db,entry,source_file,draft.reference_id,owner.scope)
            if row or reason~='offline_source_unavailable' or not NetworkLink.available(host) then return {reference=row} end
            local NativeAccess=require('weread.lib.native_read_access');local Source=require('weread.lib.source_currentness')
            local native,web=NativeAccess.capture(host.settings),Source.capture(host.settings)
            local function current_source() return host.settings:auth_scope_matches(owner.scope)
                and NativeAccess.matches(host.settings,native) and Source.matches(host.settings,web) end
            if native and not native.renewal_pending and web and web.web
                and current_source() and host:isNetworkOnline() and current_source() then
                row=refs.restore(host.client,host.settings,entry,source_file,
                    draft.reference_id,native,web,current_source,host.library_db)
            end
            return {reference=row}
        end
        local book=host.settings:get_book(owner.id)
        if book then
            book.chapters=host.library_db:getChapters(owner.id)
            local row,_,file=require('weread.lib.selection_reference').restore(book,source_file,draft.reference_id)
            if row then return {reference=row,source=file and {path=file} or nil} end
        end
        local row,source=require('weread.lib.native_direct_reference').restore_downloaded(
            host.settings,host.library_db,owner.scope,owner.id,draft.reference_id)
        return {reference=row,source=source}
    end,function(result)
        if not alive(ctx) then
            if owner.editor==ctx then done(ctx) end
            return
        end
        local latest,error_=ctx.journal:draft(draft.draft_key)
        if error_ or not latest or latest.token~=draft.token or latest.book_id~=owner.id then
            message(ctx,'This draft changed or is unavailable. Open local thought drafts again.');return
        end
        local row=type(result)=='table' and result.reference
        if row and Contract.reference_hash('create',row)==latest.base_hash then
            M.start(host,owner,'create',row,current,redraw,latest,result.source)
        else message(ctx,unavailable) end
    end)
    if not start_ok or not started then message(ctx,unavailable);return false end
    return true
end
local function cross_book(host,owner,current,draft,ctx)
    if not alive(ctx) or not current(host,owner) then return false end
    local notebook=host._notebook_owner
    local inherited=notebook and (notebook==owner or notebook.child==owner)
    local request={book_id=draft.book_id,key=draft.draft_key,token=draft.token,operation=draft.operation,
        selection=draft.operation=='create' and require('weread.lib.selection_reference').parse(draft.reference_id)~=nil}
    done(ctx)
    return require('weread.ui.my_cloud_marks').open(host,draft.book_id,draft.operation=='edit' and 'thoughts' or nil,{
        resume_draft=request,
        source=owner.menu,
        current=function() return current(host,owner) and not owner.menu._shelf_popup end,
        on_open=function(child)
            if inherited and host._notebook_owner==notebook then notebook.child=child end
        end,
    })
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
local function open_draft(ctx,preview)
    local draft,why=ctx.journal:draft(preview.draft_key)
    if why or not draft or draft.token~=preview.token or draft.book_id~=preview.book_id then
        message(ctx,'This draft changed or is unavailable. Open local thought drafts again.')
        return
    end
    local host,owner=ctx.host,ctx.owner
    local dialog
    local function valid() return alive(ctx) and Popup.current(owner.menu,dialog) end
    local buttons={{{id='delete_thought_draft',text=_('Delete local draft'),callback=function()
        if not valid() then return end
        if ctx.journal:delete_draft(draft) then message(ctx,'Local thought draft deleted.')
        else message(ctx,'Could not load local thought drafts.') end
    end}}}
    local selection=draft.operation=='create' and require('weread.lib.selection_reference').parse(draft.reference_id)
    if draft.book_id==owner.id and ((draft.operation=='edit')==owner.thoughts or selection) then
        buttons[1][2]={id='resume_thought_draft',text=_('Resume draft'),callback=function()
            if valid() then M.resume(host,owner,draft.draft_key,draft.token,ctx.current,ctx.redraw) end
        end}
    else
        buttons[1][2]={id='resume_other_book_draft',text=_('Open book and resume draft'),callback=function()
            if valid() then cross_book(host,owner,ctx.current,draft,ctx) end
        end}
    end
    dialog=require('weread.ui.thought_text').viewer{title=_('Local thought draft'),text=draft.content,buttons_table=buttons,add_default_buttons=true}
    show(ctx,dialog)
end
function M.drafts(host,owner,current,redraw)
    if not current(host,owner) then return false end
    local ctx=new_context(host,owner,current,redraw)
    local unavailable='Could not load local thought drafts.'
    local ok,worker=pcall(function()
        return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,fast_start=true}
    end)
    if not ok or not worker then message(ctx,unavailable);return false end
    local job={worker=worker};ctx.draft_job=job
    local function valid() return alive(ctx) and Popup.current(owner.menu,ctx.dialog) end
    job.notice=function()
        if ctx.draft_job~=job then return end
        if valid() then viewer(ctx,'Loading local thought drafts…','Closing this window stops the check.')
        else done(ctx) end
    end
    UI:scheduleIn(.35,job.notice)
    local started,active=pcall(worker.start,worker,function()
        local values=ctx.journal:draft_previews()
        if not values then return nil end
        local labels={}
        for _,draft in ipairs(values) do
            if draft.book_id~=owner.id then
                local label=labels[draft.book_id] or draft_book_label(host,draft.book_id)
                labels[draft.book_id]=label
                draft.label=label
            end
        end
        return {drafts=values}
    end,function(result)
        if ctx.draft_job~=job then return end
        cancel_drafts_read(ctx)
        if not valid() then done(ctx);return end
        local values=type(result)=='table' and result.drafts
        if type(values)~='table' then message(ctx,unavailable);return end
        if #values==0 then message(ctx,'No local thought drafts.');return end
        local items,menu={}
        for _,preview in ipairs(values) do
            items[#items+1]={text=preview.preview,mandatory=preview.label,callback=function()
                if alive(ctx) and Popup.current(owner.menu,menu) then open_draft(ctx,preview) end
            end}
        end
        menu=require('weread.ui.thought_text').menu{title=_('Local thought drafts'),item_table=items,is_popout=true,is_borderless=false}
        show(ctx,menu)
    end)
    if not started or not active then message(ctx,unavailable);return false end
    return true
end
return M
