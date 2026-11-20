-- Background reachability preview, explicit confirmation, cooperative deletion.
local Model=require('weread.lib.mp_cache_cleanup')
local Content=require('weread.lib.content')
local Identity=require('weread.lib.mp_cache_identity')
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function size(bytes)
    if bytes<1024 then return string.format('%d B',bytes) end
    if bytes<1024*1024 then return string.format('%.1f KB',bytes/1024) end
    return string.format('%.1f MB',bytes/1024/1024)
end
local function close(host,key)
    local widget=host[key];host[key]=nil;if widget then UIManager:close(widget) end
end
local function own(host,key,widget,job)
    host[key]=widget
    if not widget then return end
    local on_close=widget.onCloseWidget
    widget.onCloseWidget=function(instance,...)
        if host[key]==instance then
            host[key]=nil
            if key=='_mp_cleanup_menu' and job.phase=='preview' then M.cancel(host)
            elseif key=='_mp_cleanup_confirmation' then
                job.phase='preview';if not host._mp_cleanup_menu then M.cancel(host) end
            end
        end
        if on_close then return on_close(instance,...) end
    end
end
local function scope(host,book)
    local record=host.settings:get('books',{})[book.book_id or book.bookId]
    return {account=host.library_db and host.library_db:accountKey() or false,epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document or false,file=host.ui and host.ui.document and host.ui.document.file or false,
        session=host._reader_session_gen or false,cache=host.settings.cache_dir or false,record=record and record.cache_dir or false,
        root=Content.book_resolved_dir(host.settings,book.book_id or book.bookId,book)}
end
local function current(host,job)
    if host.mp_cleanup_job~=job then return false end
    local now=scope(host,job.book)
    for key,value in pairs(job.owner) do if now[key]~=value then return false end end
    return Identity.key(job.book,job.article)==job.key
end
function M.cancel(host)
    local job=host.mp_cleanup_job;host.mp_cleanup_job=nil
    close(host,'_mp_cleanup_confirmation');close(host,'_mp_cleanup_menu')
    if not job then return end
    if host.mp_cleanup_worker then host.mp_cleanup_worker:cancel() end
    if job.lock then job.lock:release() end
    if host.busy_message==job.busy then host:closeBusy() end
end
local function result(host,job,stopped)
    local files=job.deletion and job.deletion.removed_files or 0
    local bytes=job.deletion and job.deletion.removed_bytes or 0
    M.cancel(host)
    host:showInfo(T(stopped and _('Cleanup stopped. Removed %1 files, %2. Retained versions and reading records are kept.')
        or _('Cleanup complete. Removed %1 files, %2. Reading records are kept.'),files,size(bytes)))
end
local function busy(host,job,text)
    host:showBusy(text,function()
        if host.mp_cleanup_job~=job then return end
        if current(host,job) and job.deletion then result(host,job,true) else M.cancel(host) end
    end)
    job.busy=host.busy_message
end
local function failed(host,job)
    if not current(host,job) then if host.mp_cleanup_job==job then M.cancel(host) end;return end
    if job.deletion and job.deletion.removed_files>0 then result(host,job,true);return end
    M.cancel(host);host:showInfo(_('Could not clean this article cache. It changed, contains unknown files, or another task is using it. Reopen the list and try again.'))
end
local function worker(host,job,lock,callback)
    if not host.mp_cleanup_worker then
        local ok,value=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=4*1024*1024} end)
        if not ok then failed(host,job);return false end;host.mp_cleanup_worker=value
    end
    local root,key,opened=job.owner.root,job.key,job.owner.file
    local ok,started=pcall(host.mp_cleanup_worker.start,host.mp_cleanup_worker,function()
        return Model.scan(root,key,opened,lock and lock.info)
    end,function(value)
        if not current(host,job) then if host.mp_cleanup_job==job then M.cancel(host) end;return end
        local good,plan=pcall(Model.check,value,root,key,opened)
        if not good then failed(host,job);return end
        callback(plan)
    end)
    if not ok or not started then failed(host,job);return false end
    return true
end
local function apply(host,job,selected)
    if not current(host,job) then return end
    job.phase='applying'
    close(host,'_mp_cleanup_confirmation');close(host,'_mp_cleanup_menu')
    job.lock=Model.acquire(job.owner.root,job.key)
    if not job.lock then failed(host,job);return end
    busy(host,job,_('Cleaning article cache…\nTap or press a key to stop.'))
    worker(host,job,job.lock,function(plan)
        local ok,deletion=pcall(Model.begin,job.plan,selected,job.lock,plan)
        if not ok then failed(host,job);return end
        job.deletion=deletion
        local function step()
            if not current(host,job) then if host.mp_cleanup_job==job then M.cancel(host) end;return end
            local good,more,reason=pcall(Model.step,deletion)
            if not good or not more then failed(host,job)
            elseif reason=='done' then result(host,job,false)
            else UIManager:scheduleIn(.1,step) end
        end
        UIManager:scheduleIn(.1,step)
    end)
end
local function confirm(host,job,selected)
    if not current(host,job) then return end
    local ok,target=pcall(Model.targets,job.plan,selected);if not ok then failed(host,job);return end
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=selected and T(_('Remove this old article version and its unused images (%1)?\n\nThe current and open versions are kept. Reading records are not deleted, but this version will no longer open. Export any notes you need before removing it.'),size(target.bytes))
            or T(_('Remove unused article images (%1)?\n\nImages referenced by saved versions and images of the open article are kept. Text and reading records are kept.'),size(target.bytes)),
        ok_text=_('Clean up'),cancel_text=_('Cancel'),
        ok_callback=function() if host._mp_cleanup_confirmation==dialog and current(host,job) then apply(host,job,selected) end end,
        cancel_callback=function() if host._mp_cleanup_confirmation==dialog then host._mp_cleanup_confirmation=nil;job.phase='preview' end end}
    close(host,'_mp_cleanup_confirmation');job.phase='confirm';own(host,'_mp_cleanup_confirmation',dialog,job);UIManager:show(dialog)
end
local function preview(host,job,plan)
    job.plan=plan
    job.phase='preview'
    if host.busy_message==job.busy then host:closeBusy() end
    local unused=Model.targets(plan)
    local menu
    local rows={{text=_('Clean unused images'),mandatory=size(unused.bytes),select_enabled=#unused.generations>0,keep_menu_open=true,
        callback=function() if host._mp_cleanup_menu==menu then confirm(host,job,nil) end end}}
    if plan.quarantined then rows[#rows+1]={text=_('Quarantined downloads are kept. Their images are protected.'),select_enabled=false} end
    for index,item in ipairs(plan.versions) do
        rows[#rows+1]={text=T(_('Version %1 · %2'),index,os.date('%Y-%m-%d %H:%M',item.info.modification)),
            post_text=size(item.info.size),mandatory=item.current and _('Current cache') or item.opened and _('Currently reading') or _('Remove old version'),
            select_enabled=not item.current and not item.opened,keep_menu_open=true,
            callback=function() if host._mp_cleanup_menu==menu then confirm(host,job,item.name) end end}
    end
    menu=host:showList(_('Clean article cache'),rows);own(host,'_mp_cleanup_menu',menu,job)
end
function M.show(host,book,article)
    local key=Identity.key(book,article);if not key then return false end
    local waiting={}
    for _i,name in ipairs({'mp_download_worker','mp_export_worker'}) do
        local active=host[name];if active and active.job then waiting[#waiting+1]={runner=active.runner,pid=active.job.pid} end
    end
    host:closeWeReadUI()
    local job={book=book,article=article,key=key,owner=scope(host,book)};host.mp_cleanup_job=job
    busy(host,job,_('Checking article cache…\nTap or press a key to cancel.'))
    local function start()
        if not current(host,job) then if host.mp_cleanup_job==job then M.cancel(host) end;return end
        for _i,active in ipairs(waiting) do
            if active.runner and not active.runner.done(active.pid) then UIManager:scheduleIn(.2,start);return end
        end
        worker(host,job,nil,function(plan) preview(host,job,plan) end)
    end
    UIManager:scheduleIn(.1,start);return true
end
return M
