-- Current-book local notes export. The child touches only plain Lua data and
-- its newly created output descriptor, never the inherited native document.
local Notes=require('weread.lib.notes_export')
local Output=require('weread.lib.notes_export_file')
local UIManager=require('ui/uimanager')
local PluginUtil=require('weread.lib.plugin_util')
local _,T=PluginUtil.tr,PluginUtil.T
local M={}
local function scope(host)
    return {document=host.ui and host.ui.document,file=host.ui and host.ui.document and host.ui.document.file,
        account=host.library_db and host.library_db:accountKey(),session=host._reader_session_gen}
end
local function current(host,owner)
    return host.ui and host.ui.document==owner.document and owner.document and owner.document.file==owner.file
        and host._reader_session_gen==owner.session and (host.library_db and host.library_db:accountKey())==owner.account
end
local function close_picker(host)
    local picker=host._notes_export_picker;host._notes_export_picker=nil
    if picker then UIManager:close(picker) end
end
function M.cancel(host)
    close_picker(host)
    local job=host.notes_export_job;host.notes_export_job=nil
    if not job then return end
    if host.notes_export_worker then host.notes_export_worker:cancel() end
    if job.output then job.output:abort();job.output=nil end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
function M.start(host,format)
    M.cancel(host)
    local owner=scope(host)
    local annotations=host.ui and host.ui.annotation and host.ui.annotation.annotations
    if not owner.document or type(annotations)~='table' or #annotations==0 then
        host:showInfo(_('This book has no local text highlights or attached notes to export.'));return false
    end
    local props=host.ui.doc_props or {}
    local fallback=type(owner.file)=='string' and owner.file:match('([^/]+)$') or _('Untitled')
    local book={title=props.title,authors=props.authors or props.author}
    local ok,metadata=pcall(Notes.book,book,fallback)
    local directory=Notes.directory(host.settings)
    if not ok or not directory then host:showInfo(_('Could not prepare local notes export.'));return false end
    local created,output=pcall(host.create_notes_output or Output.create,directory,metadata.title,format)
    if not created or not output then host:showInfo(_('Could not create the notes export. Check storage and try again.'));return false end
    local job={owner=owner,output=output,started=os.time()}
    host.notes_export_job=job
    host:showBusy(_('Exporting local notes…\nTap or press a key to cancel.'),function() if host.notes_export_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    local function failed(reason)
        M.cancel(host)
        if reason=='notes_export/no_notes' then host:showInfo(_('This book has no local text highlights or attached notes to export.'))
        else host:showInfo(_('Could not export local notes. Check storage and try again.')) end
    end
    if not host.notes_export_worker then
        local built,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client} end)
        if not built then failed();return false end
        host.notes_export_worker=worker
    end
    local input={book=book,fallback=fallback,now=os.time(),annotations=annotations}
    local labels={author=_('Author'),note=_('Note'),page=_('Recorded page'),chapter=_('Chapter'),date=_('Exported at')}
    local started,active=pcall(host.notes_export_worker.start,host.notes_export_worker,function()
        local valid,result=pcall(Notes.write,input,format,function(value) return host.client:json_encode(value) end,
            function(bytes) return output:write(bytes) end,labels)
        if valid and output:sync() then return result end
        return {ok=false,error=not valid and type(result)=='string' and result:match('^notes_export/[a-z_]+$') or nil}
    end,function(result)
        if host.notes_export_job~=job then return end
        local age=os.time()-job.started
        if not current(host,owner) or age<0 or age>120 then M.cancel(host);return end
        if type(result)~='table' or result.ok~=true or type(result.count)~='number' or result.count<1 or result.count%1~=0
            or result.count>Notes.MAX_ITEMS or type(result.bytes)~='number' or result.bytes<1 or result.bytes>Notes.MAX_OUTPUT_BYTES
            or result.bytes%1~=0 then failed(type(result)=='table' and result.error);return end
        local accepted,complete=pcall(output.accept,output,result.bytes)
        if not accepted or not complete then failed();return end
        local path=output.path
        job.output=nil
        M.cancel(host)
        host:showInfo(T(_('Exported %1 local notes to:\n%2'),result.count,path))
    end)
    if not started or not active then failed();return false end
    return true
end
function M.show(host)
    host:closeWeReadUI()
    local owner=scope(host)
    if not owner.document then return end
    local directory=Notes.directory(host.settings)
    if not directory then host:showInfo(_('Could not prepare local notes export.'));return end
    local picker
    local function choose(format)
        return function()
            if host._notes_export_picker~=picker then return end
            close_picker(host)
            if current(host,owner) then M.start(host,format) end
        end
    end
    picker=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=T(_('Export this book’s local text highlights and attached notes to:\n%1\n\nChoose a format.'),directory),
        ok_text=_('JSON'),ok_callback=choose('json'),cancel_text=_('Cancel'),
        cancel_callback=function() if host._notes_export_picker==picker then host._notes_export_picker=nil end end,
        other_buttons={{{text=_('Markdown'),callback=choose('markdown')}}},other_buttons_first=true}
    host._notes_export_picker=picker;UIManager:show(picker)
end
return M
