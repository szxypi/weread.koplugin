-- Export the two already-saved account snapshots without fetching or changing
-- cloud data. The reader/menu owns cancellation and the worker owns no DOM.
local Model=require('weread.lib.cloud_notes_export')
local Notes=require('weread.lib.notes_export')
local Output=require('weread.lib.notes_export_file')
local Store=require('weread.lib.my_cloud_marks_store')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local PluginUtil=require('weread.lib.plugin_util')
local _,T=PluginUtil.tr,PluginUtil.T
local M={}

function M.cancel(host,owner)
    local picker=owner.export_picker;owner.export_picker=nil
    if picker and Popup.current(owner.menu,picker) then Popup.close(owner.menu) end
    local job=owner.export_job;owner.export_job=nil
    if not job then return end
    if owner.export_worker then owner.export_worker:cancel() end
    if job.output then job.output:abort();job.output=nil end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end

local function start(host,owner,current,snapshot,format)
    if not current(host,owner) or owner.export_job or owner.value~=snapshot.visible then return false end
    local directory=Notes.directory(host.settings)
    local ok,metadata=pcall(Notes.book,snapshot.book,_('WeRead notes'))
    if not ok or not directory then host:showInfo(_('Could not prepare cloud notes export.'));return false end
    local made,output=pcall(host.create_notes_output or Output.create,directory,metadata.title,format)
    if not made or not output then host:showInfo(_('Could not create the notes export. Check storage and try again.'));return false end
    local job={output=output,started=os.time()};owner.export_job=job
    host:showBusy(_('Exporting saved cloud notes…\nTap or press a key to cancel.'),function()
        if owner.export_job==job then M.cancel(host,owner) end
    end)
    job.busy=host.busy_message
    local function fail()
        M.cancel(host,owner);if current(host,owner) then host:showInfo(_('Could not export cloud notes. Check storage and try again.')) end
    end
    if not owner.export_worker then
        local built,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client} end)
        if not built or not worker then fail();return false end
        owner.export_worker=worker
    end
    local input={book_id=owner.id,book=snapshot.book,marks=snapshot.marks,thoughts=snapshot.thoughts,now=os.time()}
    local labels={author=_('Author'),date=_('Exported at'),marks=_('Cloud marks'),thoughts=_('Thoughts'),
        missing=_('Not saved on this device'),saved=_('Saved at'),time_unknown=_('Time unavailable'),chapter=_('Chapter'),quoted=_('Quoted text'),note=_('Thought'),
        highlight=_('Highlight'),bookmark=_('Bookmark'),mark=_('Cloud mark'),private=_('Private'),public=_('Public'),unknown=_('Visibility unknown')}
    local launched,active=pcall(owner.export_worker.start,owner.export_worker,function()
        local valid,result=pcall(Model.write,input,format,host.client,function(bytes) return output:write(bytes) end,labels)
        if valid and output:sync() then return result end
        return {ok=false}
    end,function(result)
        if owner.export_job~=job then return end
        local age=os.time()-job.started
        if not current(host,owner) or owner.value~=snapshot.visible or age<0 or age>120 then M.cancel(host,owner);return end
        if type(result)~='table' or result.ok~=true or type(result.count)~='number' or result.count<1
            or result.count%1~=0 or result.count>Model.MAX_ITEMS or type(result.bytes)~='number' or result.bytes<1
            or result.bytes%1~=0 or result.bytes>Model.MAX_OUTPUT_BYTES then fail();return end
        local accepted,complete=pcall(output.accept,output,result.bytes)
        if not accepted or not complete then fail();return end
        local path=output.path;job.output=nil;M.cancel(host,owner)
        host:showInfo(T(_('Exported %1 saved cloud notes to:\n%2'),result.count,path))
    end)
    if not launched or not active then fail();return false end
    return true
end

function M.show(host,owner,current)
    if not current(host,owner) or not owner.value or owner.context or owner.editor or owner.export_job then return false end
    local variant;if not owner.thoughts then variant='thoughts' end
    local ok,other=pcall(function() return Store:new(host.library_db,host.client,variant):read(owner.id) end)
    if not ok then other=nil end
    if not current(host,owner) then return false end
    local marks,thoughts
    if owner.thoughts then marks,thoughts=other,owner.value else marks,thoughts=owner.value,other end
    local count=(marks and #marks.updated or 0)+(thoughts and #thoughts.reviews or 0)
    if count==0 then host:showInfo(_('No saved cloud notes to export. Refresh the lists while online.'));return false end
    local loaded,book=pcall(host.settings.get_book,host.settings,owner.id)
    if not loaded or book~=nil and type(book)~='table' then host:showInfo(_('Could not prepare cloud notes export.'));return false end
    if not current(host,owner) then return false end
    book=book or {}
    local author=type(book.author)=='string' and book.author or type(book.authors)=='string' and book.authors or ''
    local snapshot={visible=owner.value,marks=marks,thoughts=thoughts,book={
        title=type(book.title)=='string' and book.title or _('WeRead notes'),
        author=author}}
    local function describe(value,rows)
        return value and tostring(#value[rows]) or _('Not saved or unavailable')
    end
    local dialog
    local function choose(format)
        return function()
            if not current(host,owner) or owner.export_picker~=dialog or not Popup.current(owner.menu,dialog) then return end
            owner.export_picker=nil;Popup.close(owner.menu)
            start(host,owner,current,snapshot,format)
        end
    end
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=T(_('Export all saved cloud marks and thoughts, regardless of the current filter.\nMarks: %1\nThoughts: %2\n\nOnly data saved on this device is included.'),
            describe(marks,'updated'),describe(thoughts,'reviews')),
        ok_text=_('JSON'),ok_callback=choose('json'),cancel_text=_('Cancel'),
        cancel_callback=function() if owner.export_picker==dialog then owner.export_picker=nil end end,
        other_buttons={{{text=_('Markdown'),callback=choose('markdown')}}},other_buttons_first=true}
    dialog.onCloseWidget=function() if owner.export_picker==dialog then owner.export_picker=nil end end
    owner.export_picker=dialog;Popup.show(owner.menu,dialog)
    return true
end
return M
