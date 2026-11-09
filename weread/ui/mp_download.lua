-- Native cancellable article download. Network and conversion run in a child.
local Model=require('weread.lib.mp_download')
local Stage=require('weread.lib.mp_download_stage')
local UIManager=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function scope(host)
    return {account=host.library_db and host.library_db:accountKey(),epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document,file=host.ui and host.ui.document and host.ui.document.file,
        session=host._reader_session_gen,cache=host.settings.cache_dir}
end
local function current(host,owner,input)
    return owner.account==(host.library_db and host.library_db:accountKey()) and owner.epoch==(host.discovery_epoch or 0)
        and owner.document==(host.ui and host.ui.document) and owner.file==(host.ui and host.ui.document and host.ui.document.file)
        and owner.session==host._reader_session_gen and owner.cache==host.settings.cache_dir and Model.matches(host.settings,input)
end
local function dispose(job,worker)
    job.stage:close()
    local function reap()
        if job.pid and worker and worker.runner and not worker.runner.done(job.pid) then
            UIManager:scheduleIn(.2,reap);return
        end
        job.stage:cleanup()
    end
    reap()
end
function M.cancel(host)
    local job=host.mp_download_job;host.mp_download_job=nil
    if not job then return end
    local worker=host.mp_download_worker
    if worker then worker:cancel() end
    dispose(job,worker)
    if job.busy and job.busy==host.busy_message then host:closeBusy() end
end
local function failed(host)
    host:showInfo(_('Could not download this article. Check login, network and storage, then try again. The previous cache is kept.'))
end
function M.start(host,book,article)
    if not host:requireLogin(true,false) then return false end
    if not host:isNetworkConnected() then host:showOffline(_('Download article and read'));return false end
    host:closeWeReadUI()
    local owner=scope(host)
    local captured,input=pcall(Model.capture,host.settings,book,article)
    if not captured or not input then failed(host);return false end
    local created,stage=pcall(host.create_mp_stage or Stage.create,input.root,input.key)
    if not created or not stage then failed(host);return false end
    local job={owner=owner,input=input,stage=stage,started=os.time()};host.mp_download_job=job
    host:showBusy(_('Downloading article…\nTap or press a key to cancel.'),function() if host.mp_download_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    local function stop() M.cancel(host);failed(host) end
    if not host.mp_download_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client} end)
        if not ok then stop();return false end;host.mp_download_worker=worker
    end
    local labels={missing=_('Image unavailable')}
    local ok,started=pcall(host.mp_download_worker.start,host.mp_download_worker,function()
        return Model.write(host.client,input,stage,labels)
    end,function(result)
        if host.mp_download_job~=job then return end
        local age=os.time()-job.started
        if not current(host,owner,input) or age<0 or age>120 then M.cancel(host);return end
        -- Refuse a concurrent book-cache move before publishing or saving a pin.
        local records=host.settings:get('books',{})
        local latest=records[input.book_id]
        if type(latest)=='table' and latest.cache_dir and latest.cache_dir~='' and latest.cache_dir~=input.root then M.cancel(host);return end
        local committed,path=pcall(stage.commit,stage,result)
        if not committed or not path then stop();return end
        host.mp_download_job=nil
        if host.busy_message==job.busy then host:closeBusy() end
        -- Re-read and merge only the resolved directory; keep progress and intent.
        local saved=pcall(function()
            records=host.settings:get('books',{})
            local record=records[input.book_id] or {}
            record.cache_dir=input.root;records[input.book_id]=record
            host.settings:set('books',records);host.settings:flush()
        end)
        if not saved then
            host:showInfo(_('The article was downloaded, but its library record could not be saved. Please check available storage.'))
            return
        end
        host:openFile(path)
    end)
    if not ok or not started then stop();return false end
    job.pid=host.mp_download_worker.job and host.mp_download_worker.job.pid
    return true
end
return M
