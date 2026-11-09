-- Native explicit snapshot selection; all inspection/copy work stays offline.
local Model=require('weread.lib.mp_record_recovery')
local Store=require('weread.lib.mp_records_db')
local Stage=require('weread.lib.mp_download_stage')
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local fields={'_mp_records_menu','_mp_records_confirmation'}
local function close(host,key)
    local widget=host[key];host[key]=nil;if widget then UIManager:close(widget) end
end
local function own(host,key,widget)
    host[key]=widget;local previous=widget.onCloseWidget
    widget.onCloseWidget=function(instance,...)
        if host[key]==instance then host[key]=nil;M.cancel(host) end
        if previous then return previous(instance,...) end
    end
end
local function scope(host,book)
    local record=host.settings:get('books',{})[book.book_id or book.bookId]
    return {account=host.library_db and host.library_db:accountKey() or false,epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document or false,file=host.ui and host.ui.document and host.ui.document.file or false,
        session=host._reader_session_gen or false,cache=host.settings.cache_dir or false,record=record and record.cache_dir or false}
end
local function current(host,job)
    if host.mp_records_job~=job then return false end
    local now=scope(host,job.book)
    for key,value in pairs(job.owner) do if now[key]~=value then return false end end
    return Model.matches(host.settings,job.book,job.article,job.input)
end
local function dispose(stage,worker,pid)
    stage:close()
    local function reap()
        if pid and worker and worker.runner and not worker.runner.done(pid) then UIManager:scheduleIn(.2,reap);return end
        stage:cleanup()
    end
    reap()
end
function M.cancel(host)
    local job=host.mp_records_job;host.mp_records_job=nil
    for _i,key in ipairs(fields) do close(host,key) end
    if not job then return end
    local worker=host.mp_records_worker
    local pid=worker and worker.job and worker.job.pid or job.pid
    if worker then worker:cancel() end
    if job.stage then dispose(job.stage,worker,pid) end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function failed(host)
    host:showInfo(_('Could not complete reading record recovery. The original text and saved records are kept. Reopen the article list to check the current version before trying again.'))
end
local function stop(host) M.cancel(host);failed(host) end
local function busy(host,job,text)
    host:showBusy(text,function() if host.mp_records_job==job then M.cancel(host) end end);job.busy=host.busy_message
end
local function clear_busy(host,job)
    if host.busy_message==job.busy then host:closeBusy() end;job.busy=nil
end
local function apply(host,job,id)
    if not current(host,job) then M.cancel(host);return end
    close(host,'_mp_records_confirmation');close(host,'_mp_records_menu')
    local ok,stage=pcall(host.create_mp_stage or Stage.create,job.input.root,job.input.key,{preserve=true})
    if not ok or not stage then stop(host);return end
    job.stage=stage;job.started=os.time()
    busy(host,job,_('Restoring reading records…\nTap or press a key to cancel.'))
    local active,started=pcall(host.mp_records_worker.start,host.mp_records_worker,function()
        return Model.write(job.input,stage,job.sha256)
    end,function(result)
        if host.mp_records_job~=job then return end
        local age=os.time()-job.started
        if not current(host,job) or age<0 or age>120 then M.cancel(host);return end
        local committed,path=pcall(stage.commit,stage,result,true)
        if not committed or not path then stop(host);return end
        local restored,good=pcall(Model.restore,job.store,job.input,id,path)
        if not restored or not good then stop(host);return end
        local published,complete=pcall(stage.publish_deferred,stage)
        if not published or not complete then stop(host);return end
        host.mp_records_job=nil;clear_busy(host,job);host:openFile(path)
    end)
    if not active or not started then stop(host);return end
    job.pid=host.mp_records_worker.job and host.mp_records_worker.job.pid
end
local warning='Saved records can belong to another version. Choose a record that matches this text; overwritten records cannot be reconstructed. A separate copy becomes the current cache only after it is saved. The original text and saved snapshots are kept.'
local function confirm(host,job,row)
    if not current(host,job) then M.cancel(host);return end
    local text
    if row then
        local excerpt=row.preview
        if row.note_preview~='' then excerpt=excerpt..'\n\n'..T(_('Attached note: %1'),row.note_preview) end
        text=T(_('Restore a separate copy of this text using the selected record?\n\n%1\n\nNotes: %2 · Bookmarks: %3\nSaved position: %4\n\n%5'),
            job.article.title or _('Article'),row.notes,row.bookmarks,row.has_position and _('Yes') or _('No'),excerpt)
    else text=_('Open an independent copy without applying positions or notes? Saved record snapshots remain available for recovery.') end
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,text=text..'\n\n'.._(warning),
        ok_text=row and _('Restore to new copy') or _('Open new copy'),cancel_text=_('Cancel'),
        ok_callback=function() if host._mp_records_confirmation==dialog then apply(host,job,row and row.id or false) end end,
        cancel_callback=function() if host._mp_records_confirmation==dialog then host._mp_records_confirmation=nil end end}
    close(host,'_mp_records_confirmation');own(host,'_mp_records_confirmation',dialog);UIManager:show(dialog)
end
local function preview(host,job,rows)
    local labels={primary=_('Saved primary record'),backup=_('Saved backup record'),live=_('Record before closing'),
        beside=_('Record beside the text'),beside_backup=_('Backup beside the text'),
        folder=_('Record in metadata folder'),folder_backup=_('Backup in metadata folder'),
        legacy_beside=_('Older record beside the text'),history=_('History record'),
        history_backup=_('History backup'),compatibility=_('Older compatibility record')}
    local items,menu={}
    local function integer(value,max) return type(value)=='number' and value>=0 and value<=max and value%1==0 end
    for _i,row in ipairs(rows) do
        if type(row)~='table' or not labels[row.kind] or type(row.id)~='string' or #row.id~=64 or not row.id:match('^[a-f0-9]+$')
            or type(row.valid)~='boolean' or not integer(row.notes,100000) or not integer(row.bookmarks,100000)
            or not integer(row.saved_at,4102444800) or type(row.has_position)~='boolean'
            or type(row.preview)~='string' or #row.preview>1024 or type(row.note_preview)~='string' or #row.note_preview>1024 then stop(host);return end
        items[#items+1]={text=T(_('%1 · %2'),labels[row.kind],os.date('%Y-%m-%d %H:%M',row.saved_at)),
            mandatory=row.valid and T(_('%1 notes · %2 bookmarks'),row.notes,row.bookmarks) or _('Unreadable record'),
            select_enabled=row.valid,callback=function() if host._mp_records_menu==menu and row.valid then confirm(host,job,row) end end}
    end
    items[#items+1]={text=_('Open new copy without records'),callback=function() if host._mp_records_menu==menu then confirm(host,job) end end}
    items[#items+1]={text=_('About reading record recovery'),callback=function() if host._mp_records_menu==menu and current(host,job) then host:showInfo(_(warning)) end end}
    menu=host:showList(_('Recover reading records'),items);own(host,'_mp_records_menu',menu)
end
function M.show(host,book,article,path,automatic)
    M.cancel(host)
    local captured,input=pcall(Model.capture,host.settings,book,article,path)
    if not captured or not input then failed(host);return false end
    local frozen,rows=pcall(Model.freeze,input)
    if not frozen then failed(host);return false end
    local prior=scope(host,book);local store=Store.new(host.settings,prior.account)
    local ok=pcall(function()
        local ui=host.ui
        if ui and ui.document and ui.doc_settings and Model.hash_directory(ui.document.file)==Model.hash_directory(input.path) then
            ui:handleEvent(require('ui/event'):new('SaveSettings'))
            rows[#rows+1]={kind='live',raw='return '..require('dump')(ui.doc_settings.data,nil,true)}
        end
    end)
    if not ok then failed(host);return false end
    if automatic and #rows==0 and (not store or not store:exists()) then host:openFile(input.path);return true end
    -- Menus and ordinary KOReader saves may flush/migrate the open document.
    -- Commit its bounded snapshots before closing widgets or yielding to them.
    local preserved,good=pcall(Model.preserve,store,input,rows)
    if not preserved or not good then failed(host);return false end
    host:closeWeReadUI()
    local owner=scope(host,book)
    if owner.account~=prior.account or not Model.matches(host.settings,book,article,input) then failed(host);return false end
    local job={book=book,article=article,input=input,owner=owner,started=os.time(),store=store}
    host.mp_records_job=job
    busy(host,job,_('Preserving reading records…\nTap or press a key to cancel.'))
    if not host.mp_records_worker then
        local built,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=512*1024} end)
        if not built then stop(host);return false end;host.mp_records_worker=worker
    end
    local active,started=pcall(host.mp_records_worker.start,host.mp_records_worker,function() return Model.prepare(job.store,input) end,function(result)
        if host.mp_records_job~=job then return end
        local age=os.time()-job.started
        if not current(host,job) or age<0 or age>120 then M.cancel(host);return end
        if type(result)~='table' or result.ok~=true or type(result.rows)~='table' or #result.rows>Store.MAX_RECORDS
            or type(result.source_sha256)~='string' or #result.source_sha256~=64 or not result.source_sha256:match('^[a-f0-9]+$') then stop(host);return end
        job.sha256=result.source_sha256;clear_busy(host,job)
        if #result.rows==0 then
            host.mp_records_job=nil
            if automatic then host:openFile(input.path) else host:showInfo(_('No saved reading records for this article.')) end
        else preview(host,job,result.rows) end
    end)
    if not active or not started then stop(host);return false end
    job.pid=host.mp_records_worker.job and host.mp_records_worker.job.pid
    return true
end
function M.open(host,book,article,path)
    local ok,input,reason=pcall(Model.capture,host.settings,book,article,path)
    if not ok then failed(host);return false end
    if reason=='legacy' or input and input.stamped then host:openFile(path);return true end
    return M.show(host,book,article,path,true)
end
return M
