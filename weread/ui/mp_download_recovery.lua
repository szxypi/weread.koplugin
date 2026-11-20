-- Local-only interrupted-download inspection and explicitly confirmed repair.
local Model=require('weread.lib.mp_download_recovery')
local Content=require('weread.lib.content')
local Identity=require('weread.lib.mp_cache_identity')
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function size(n)
    if n<1024 then return string.format('%d B',n) end
    if n<1024*1024 then return string.format('%.1f KB',n/1024) end
    return string.format('%.1f MB',n/1024/1024)
end
local function close(host,key) local view=host[key];host[key]=nil;if view then UIManager:close(view) end end
local function own(host,key,view,job)
    host[key]=view
    if view then
        local on_close=view.onCloseWidget
        view.onCloseWidget=function(instance,...)
            if host[key]==instance then
                host[key]=nil
                if job and key=='_mp_recovery_view' and job.phase=='preview' then M.cancel(host)
                elseif job and key=='_mp_recovery_confirmation' then
                    job.phase='preview';if not host._mp_recovery_view then M.cancel(host) end
                end
            end
            if on_close then return on_close(instance,...) end
        end
    end
end
local function scope(host,book)
    local record=host.settings:get('books',{})[book.book_id or book.bookId]
    return {account=host.library_db and host.library_db:accountKey() or false,epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document or false,file=host.ui and host.ui.document and host.ui.document.file or false,
        session=host._reader_session_gen or false,cache=host.settings.cache_dir or false,record=record and record.cache_dir or false,
        root=Content.book_resolved_dir(host.settings,book.book_id or book.bookId,book)}
end
local function same_scope(host,job)
    local now=scope(host,job.book)
    for key,value in pairs(job.owner) do if now[key]~=value then return false end end
    return Identity.key(job.book,job.article)==job.key
end
local function current(host,job) return host.mp_recovery_job==job and same_scope(host,job) end
function M.cancel(host)
    local job=host.mp_recovery_job;host.mp_recovery_job=nil
    for _i,key in ipairs({'_mp_recovery_confirmation','_mp_recovery_view','_mp_recovery_picker','_mp_recovery_result'}) do close(host,key) end
    if not job then return end
    if host.mp_recovery_worker then host.mp_recovery_worker:cancel() end
    if job.repair then Model.release(job.repair) end
    if job.gate then job.gate:release() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function failed(host,job)
    if host.mp_recovery_job~=job then return end
    local visible=same_scope(host,job);local repair=job.repair
    M.cancel(host)
    if visible then
        if repair and repair.files>0 then host:showInfo(T(_('Repair stopped. Removed %1 files, %2. Saved articles and reading records are kept.'),repair.files,size(repair.bytes)))
        else host:showInfo(_('Could not repair this download. Its state changed, it is in use, or the operation is unsupported. Please check again.')) end
    end
end
local function finished(host,job)
    local repair=job.repair
    local text=repair.action=='quarantine' and _('Download quarantined. No content was deleted or space freed. Its images are protected. You can restore it from this list.')
        or repair.action=='restore' and _('Download restored to its original location.')
        or T(_('Temporary download removed: %1 files, %2. Saved articles and reading records are kept.'),repair.files,size(repair.bytes))
    M.cancel(host)
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,text=text,ok_text=_('Check again'),cancel_text=_('Close'),
        ok_callback=function()
            if host._mp_recovery_result~=dialog then return end;close(host,'_mp_recovery_result')
            if same_scope(host,job) then M.show(host,job.book,job.article) end
        end,cancel_callback=function() if host._mp_recovery_result==dialog then host._mp_recovery_result=nil end end}
    own(host,'_mp_recovery_result',dialog);UIManager:show(dialog)
end
local function busy(host,job,text)
    host:showBusy(text,function()
        if host.mp_recovery_job~=job then return end
        if job.repair and job.repair.files>0 then failed(host,job) else M.cancel(host) end
    end);job.busy=host.busy_message
end
local function worker(host,job,callback)
    if not host.mp_recovery_worker then
        local ok,value=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=4*1024*1024} end)
        if not ok then failed(host,job);return end;host.mp_recovery_worker=value
    end
    local root,key,opened=job.owner.root,job.key,job.owner.file
    local ok,started=pcall(host.mp_recovery_worker.start,host.mp_recovery_worker,function() return Model.scan(root,key,opened) end,function(value)
        if not current(host,job) then if host.mp_recovery_job==job then M.cancel(host) end;return end
        local valid,plan=pcall(Model.check,value,root,key,opened)
        if not valid then failed(host,job);return end;callback(plan)
    end)
    if not ok or not started then failed(host,job) end
end
local function apply(host,job,item,action)
    if not current(host,job) then return end
    job.phase='applying'
    close(host,'_mp_recovery_confirmation');close(host,'_mp_recovery_view')
    job.gate=require('weread.lib.mp_cache_cleanup').acquire(job.owner.root,job.key)
    if not job.gate then failed(host,job);return end
    busy(host,job,_('Repairing download…\nTap or press a key to stop.'))
    worker(host,job,function(fresh)
        local valid,repair=pcall(Model.begin,job.plan,fresh,item.nonce,action,job.gate)
        if not valid then failed(host,job);return end;job.repair=repair
        local function step()
            if not current(host,job) then if host.mp_recovery_job==job then M.cancel(host) end;return end
            local ok,good,reason=pcall(Model.step,repair)
            if not ok or not good then failed(host,job)
            elseif reason=='done' then finished(host,job) else UIManager:scheduleIn(.1,step) end
        end
        UIManager:scheduleIn(.1,step)
    end)
end
local function confirm(host,job,item)
    if not current(host,job) then return end
    local action=item.status=='unknown' and 'quarantine' or item.status=='quarantine' and 'restore' or 'clean'
    local text
    if action=='quarantine' then text=_('Close other readers and download tasks first. This directory has no reliable ownership record; continuing confirms those tasks have stopped. Quarantine moves the whole directory without deleting it or freeing space. You can restore it later.')
    elseif action=='restore' then text=_('Restore this quarantined download? The original location must be empty. Existing files will not be replaced.')
    elseif item.status=='owned' then text=T(_('Remove this interrupted temporary download (%1)? Saved articles, their images and reading records are kept.'),size(item.bytes))
    else text=T(_('Remove this leftover download record (%1)? The article, images and reading records are kept.'),size(item.bytes)) end
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,text=text,
        ok_text=action=='quarantine' and _('Quarantine') or action=='restore' and _('Restore') or _('Clean up'),cancel_text=_('Cancel'),
        ok_callback=function() if host._mp_recovery_confirmation==dialog then apply(host,job,item,action) end end,
        cancel_callback=function() if host._mp_recovery_confirmation==dialog then host._mp_recovery_confirmation=nil;job.phase='preview' end end}
    close(host,'_mp_recovery_confirmation');job.phase='confirm';own(host,'_mp_recovery_confirmation',dialog,job);UIManager:show(dialog)
end
local function preview(host,job,plan)
    job.plan=plan
    job.phase='preview'
    if host.busy_message==job.busy then host:closeBusy() end
    if #plan.items==0 then M.cancel(host);host:showInfo(_('No interrupted downloads found for this article.'));return end
    local labels={active=_('In use'),owned=_('Interrupted download'),completed=_('Completed; record remains'),record=_('Leftover record'),
        unknown=_('Ownership unknown'),quarantine=_('Quarantined'),protected=_('Protected by saved content'),conflict=_('Conflicting state; kept'),unknown_record=_('Unknown record; kept')}
    local rows,menu={}
    for index,item in ipairs(plan.items) do
        local info=item.info or item.record_info
        local usable=not plan.active and (item.status=='owned' or item.status=='completed' or item.status=='record' or item.status=='unknown' or item.status=='quarantine')
        rows[#rows+1]={text=T(_('Download %1 · %2'),index,info and os.date('%Y-%m-%d %H:%M',info.modification) or _('Unknown')),
            mandatory=labels[item.status],post_text=item.status=='owned' and size(item.bytes) or '',select_enabled=usable,keep_menu_open=true,
            callback=function() if host._mp_recovery_view==menu and usable then confirm(host,job,item) end end}
    end
    if plan.active then rows[#rows+1]={text=_('Another download is in use. Wait for it to finish, then check again.'),select_enabled=false} end
    rows[#rows+1]={text=_('Check again'),callback=function() if host._mp_recovery_view==menu and current(host,job) then M.show(host,job.book,job.article) end end}
    menu=host:showList(_('Repair interrupted downloads'),rows);own(host,'_mp_recovery_view',menu,job)
end
function M.show(host,book,article)
    local key=Identity.key(book,article);if not key then return false end
    local waiting={}
    for _i,name in ipairs({'mp_download_worker','mp_export_worker'}) do
        local value=host[name];if value and value.job then waiting[#waiting+1]={pid=value.job.pid,runner=value.runner} end
    end
    host:closeWeReadUI()
    local job={book=book,article=article,key=key,owner=scope(host,book)};host.mp_recovery_job=job
    busy(host,job,_('Checking interrupted downloads…\nTap or press a key to cancel.'))
    local function start()
        if not current(host,job) then if host.mp_recovery_job==job then M.cancel(host) end;return end
        for _i,value in ipairs(waiting) do if value.runner and not value.runner.done(value.pid) then UIManager:scheduleIn(.2,start);return end end
        worker(host,job,function(plan) preview(host,job,plan) end)
    end
    UIManager:scheduleIn(.1,start);return true
end
function M.list(host,book,articles)
    host:closeWeReadUI()
    local owner={book=book,article={},owner=scope(host,book)};local rows,menu,seen={},nil,{}
    for index,article in ipairs(articles or {}) do
        if index>1000 then break end
        local key=Identity.key(book,article)
        if key and not seen[key] then
            seen[key]=true;rows[#rows+1]={text=article.title or _('Article'),callback=function()
                if host._mp_recovery_picker~=menu then return end
                local now=scope(host,book);for k,v in pairs(owner.owner) do if now[k]~=v then return end end
                M.show(host,book,article)
            end}
        end
    end
    menu=host:showList(_('Choose an article to inspect'),rows,_('No articles.'));own(host,'_mp_recovery_picker',menu)
end
return M
