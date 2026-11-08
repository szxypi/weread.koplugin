-- Manual read-only cloud navigation, bound to the current reader and session.
local Cloud=require('weread.lib.source_cloud')
local Context=require('weread.lib.source_context')
local Identity=require('weread.lib.book_file_identity')
local Source=require('weread.lib.position_source')
local UIManager=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function location(host,document)
    return Context.location(document,host.ui and host.ui.view and host.ui.view.view_mode)
end
local function current(host,job,allow_movement)
    if host.cloud_source_request~=job or not host.ui or host.ui.document~=job.document
        or job.document.file~=job.file or host._reader_session_gen~=job.session
        or tostring(host:detectWeReadBook() or '')~=job.book_id or not Cloud.matches(host.settings,job.access) then return false end
    if host.progress_sync and not job.dispatching and host.progress_sync.navigation_generation~=job.navigation_generation then return false end
    local now=os.time()
    if now<job.started or now-job.started>120 or Identity.read_document(job.document,job.book_id).file_id~=job.identity.file_id then return false end
    return allow_movement or Context.same_location(job.location,location(host,job.document))
end
function M.cancel(host)
    local job=host.cloud_source_request
    host.cloud_source_request=nil
    if not job then return end
    if host.cloud_source_worker then host.cloud_source_worker:cancel() end
    if job.navigation and host.source_navigation and host.source_navigation.job==job.navigation then host.source_navigation:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
    if host.source_position then host.source_position:resume('cloud_source') end
end
function M.on_view_changed(host)
    local job=host.cloud_source_request
    if not job or (job.navigation and host.source_navigation and host.source_navigation.committing) then return end
    if not current(host,job) then M.cancel(host) end
end
function M.navigation_cancelled(host,navigation)
    local job=host.cloud_source_request
    if job and job.navigation==navigation then M.cancel(host) end
end
function M.start(host)
    M.cancel(host)
    local id=tostring(host:detectWeReadBook() or '')
    local document=host.ui and host.ui.document
    local access=Cloud.capture(host.settings)
    if not access or not access.web then
        if host.qr_login then
            host:showTransientInfo(_('Please scan the QR code to log in first.'),2)
            UIManager:scheduleIn(0.2,function() host.qr_login:start() end)
        else host:requireLogin(true,false) end
        return false
    end
    if not host:isNetworkOnline() then host:showOffline(_('Cloud reading position'));return false end
    local identity=document and Identity.read_document(document,id)
    local at=document and location(host,document)
    if not identity or not identity.file_id or not at or not host.source_navigation then
        host:showInfo(_('This file has no matching original text. Download the target chapter or full book and try again.'));return false
    end
    if (host.read_report and host.read_report.job) or (host.source_position
        and (not host.source_position.can_prepare() or host.source_position.is_busy())) then
        host:showInfo(_('Reading position is temporarily unavailable. Please try again shortly.'));return false
    end
    host.source_navigation:cancel()
    if host.progress_sync then
        local ok=pcall(host.progress_sync.begin_cloud_source_navigation,host.progress_sync)
        if not ok then host:showInfo(_('Could not verify the cloud reading position. Your current location is kept.'));return false end
    end
    host.cloud_source_sequence=(host.cloud_source_sequence or 0)+1
    local job={document=document,file=document.file,identity=identity,book_id=id,access=access,location=at,
        session=host._reader_session_gen,started=os.time(),sequence=host.cloud_source_sequence,
        navigation_generation=host.progress_sync and host.progress_sync.navigation_generation}
    host.cloud_source_request=job
    if host.source_position then host.source_position:pause('cloud_source') end
    host:showBusy(_('Checking cloud reading position...'),function() M.cancel(host) end)
    job.busy=host.busy_message
    local function finish(reason,success)
        if host.cloud_source_request~=job then return end
        job.navigation=nil
        M.cancel(host)
        if success then host:showTransientInfo(_('Cloud reading position opened. Progress reporting is waiting for verification.'),3)
        elseif reason=='source_changed' or reason=='source_unavailable' then
            host:showInfo(_('This file has no matching original text. Download the target chapter or full book and try again.'))
        elseif job.navigating then host:showInfo(_('Could not locate the cloud position in this file. Please check the current page.'))
        else host:showInfo(_('Could not verify the cloud reading position. Your current location is kept.')) end
    end
    if not host.cloud_source_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=65536} end)
        if not ok then finish('worker_unavailable');return false end
        host.cloud_source_worker=worker
    end
    local input={file=job.file,identity=identity,book_id=id,request_id=job.sequence}
    local ok,started=pcall(host.cloud_source_worker.start,host.cloud_source_worker,function()
        local valid,result=pcall(function() return Cloud.bind(input,Cloud.fetch(host.client,id,access)) end)
        return valid and result or {error='cloud_unavailable'}
    end,function(result)
        if not current(host,job) then if host.cloud_source_request==job then M.cancel(host) end return end
        local position=type(result)=='table' and result.position
        local snapshot=type(position)=='table' and Source.document_metadata(document,id,position.chapter_uid,position.render_path)
        if not snapshot or result.request_id~=job.sequence or snapshot.metadata~=result.metadata then
            finish(type(result)=='table' and result.error or 'target_unavailable');return
        end
        job.dispatching,job.navigating,job.started=true,true,os.time()
        local called,opened=pcall(host.openSourcePosition,host,position,function(applied,reason)
            if not current(host,job,true) then if host.cloud_source_request==job then M.cancel(host) end return end
            if applied and host.progress_sync then
                local saved,accepted=pcall(host.progress_sync.accept_cloud_source_target,host.progress_sync,applied)
                if not saved or accepted~=true then
                    job.navigation=nil;M.cancel(host)
                    host:showInfo(_('Cloud position opened, but sync state could not be saved. Check storage before syncing.'));return
                end
            end
            finish(reason,applied~=nil)
        end)
        job.dispatching=nil
        if not called or not opened then finish('target_unavailable');return end
        if host.cloud_source_request==job then
            job.navigation=host.source_navigation.job
            job.navigation_generation=host.progress_sync and host.progress_sync.navigation_generation
        end
    end)
    if not ok or not started then finish('worker_unavailable');return false end
    return true
end
return M
