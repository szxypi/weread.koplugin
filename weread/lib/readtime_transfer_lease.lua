-- Pause only this plugin's writers. Never abandon an already running upload.
local M={}
function M.acquire(host,book,current)
    local report,sync=host.read_report,host.progress_sync
    local upload=host.source_upload
    if host._offline_time_transfer_lock or host._native_direct_position
        or report and (report.job or report.preparation or report.offline_time_transfer)
        or sync and (sync.upload_job or sync.uploading or sync.offline_time_transfer)
        or upload and (upload.job or upload.native and (upload.native.job or upload.native.service.job)) then return nil,'busy' end
    local store=require('weread.lib.native_position_store'):new(host.library_db,host.client)
    local record,reason=store:read()
    if reason or not record then return nil,'storage' end
    if record.phase~='idle' and record.metadata.book_id==book then return nil,'position_pending' end
    local token={};host._offline_time_transfer_lock=token
    local running=report and report.task~=nil
    local interval=sync and sync.interval and (sync.interval.task~=nil or sync.interval.cycle~=nil)
    if report then report.offline_time_transfer=token;report:stop('offline_transfer') end
    if sync then sync.offline_time_transfer=token;if sync.interval then sync.interval:halt() end end
    return function(resume)
        if host._offline_time_transfer_lock~=token then return end
        host._offline_time_transfer_lock=nil
        if report and report.offline_time_transfer==token then report.offline_time_transfer=nil end
        if sync and sync.offline_time_transfer==token then sync.offline_time_transfer=nil end
        if not resume or not current() then return end
        if running and host.read_report==report then report:start('offline_transfer_finished') end
        if interval and host.progress_sync==sync then sync.interval:refresh() end
    end
end
return M
