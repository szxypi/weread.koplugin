-- Manual read-only cloud navigation, bound to the current reader and session.
local Cloud=require('weread.lib.source_cloud')
local Context=require('weread.lib.source_context')
local Handoff=require('weread.lib.cloud_source_handoff')
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
    if now<job.started or now-job.started>(job.downloading and 1800 or 120)
        or Identity.read_document(job.document,job.book_id).file_id~=job.identity.file_id then return false end
    return allow_movement or Context.same_location(job.location,location(host,job.document))
end
local function close_busy(host,job)
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
    job.busy=nil
end
function M.cancel(host)
    local incoming=host.cloud_source_incoming
    host.cloud_source_incoming=nil
    if incoming then UIManager:unschedule(incoming.task) end
    local job=host.cloud_source_request
    host.cloud_source_request=nil
    if not job then return end
    if host.cloud_source_worker then host.cloud_source_worker:cancel() end
    if job.task then UIManager:unschedule(job.task) end
    if job.confirm then UIManager:close(job.confirm) end
    if job.download and host.downloader then host.downloader:cancelJob(job.download,'cancelled') end
    if job.navigation and host.source_navigation and host.source_navigation.job==job.navigation then host.source_navigation:cancel() end
    close_busy(host,job)
    if host.source_position then host.source_position:resume('cloud_source') end
end
function M.on_view_changed(host)
    local incoming=host.cloud_source_incoming
    if incoming and not Context.same_location(incoming.location,location(host,incoming.document)) then M.cancel(host) end
    local job=host.cloud_source_request
    if not job or (job.navigation and host.source_navigation and host.source_navigation.committing) then return end
    if not current(host,job) then M.cancel(host) end
end
function M.navigation_cancelled(host,navigation)
    local job=host.cloud_source_request
    if job and job.navigation==navigation then M.cancel(host) end
end
local function receive(host,remote,file_id,access,sync_choice)
    M.cancel(host)
    local document=host.ui and host.ui.document
    local incoming={document=document,location=document and location(host,document),session=host._reader_session_gen,started=os.time()}
    incoming.task=function()
        if host.cloud_source_incoming~=incoming then return end
        host.cloud_source_incoming=nil
        local age=os.time()-incoming.started
        if age<0 or age>120 or host.ui.document~=document or host._reader_session_gen~=incoming.session
            or host.progress_sync.navigation_generation~=0 or not Cloud.matches(host.settings,access)
            or Identity.read_document(document,remote.book_id).file_id~=file_id
            or not Context.same_location(incoming.location,location(host,document)) then return end
        M.start(host,{remote=remote,file_id=file_id,access=access},{sync_choice=sync_choice==true})
    end
    host.cloud_source_incoming=incoming
    -- ReaderUI's after-open callback precedes installation of its new instance.
    UIManager:scheduleIn(0.1,incoming.task)
    return true
end
function M.start(host,resume,options)
    M.cancel(host)
    local id=tostring(host:detectWeReadBook() or '')
    local document=host.ui and host.ui.document
    local access=Cloud.capture(host.settings)
    local remote=resume and Cloud.remote(resume.remote)
    if resume and (not remote or remote.book_id~=id or not Cloud.matches(host.settings,resume.access)) then return false end
    if not access or not access.web then
        if host.qr_login then
            host:showTransientInfo(_('Please scan the QR code to log in first.'),2)
            UIManager:scheduleIn(0.2,function() host.qr_login:start() end)
        else host:requireLogin(true,false) end
        return false
    end
    if not resume and not host:isNetworkOnline() then host:showOffline(_('Cloud reading position'));return false end
    local identity=document and Identity.read_document(document,id)
    local at=document and location(host,document)
    if not identity or not identity.file_id or not at or not host.source_navigation then
        host:showInfo(_('This file has no matching original text. Download the target chapter or full book and try again.'));return false
    end
    if resume and identity.file_id~=resume.file_id then return false end
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
        navigation_generation=host.progress_sync and host.progress_sync.navigation_generation,
        sync_choice=options and options.sync_choice==true or false}
    host.cloud_source_request=job
    if host.source_position then host.source_position:pause('cloud_source') end
    local function busy()
        host:showBusy(_('Checking cloud reading position...'),function() if host.cloud_source_request==job then M.cancel(host) end end)
        job.busy=host.busy_message
    end
    local function finish(reason,success)
        if host.cloud_source_request~=job then return end
        job.navigation=nil
        M.cancel(host)
        if success then host:showTransientInfo(_('Cloud reading position opened. Progress reporting is waiting for verification.'),3)
        elseif reason=='cloud_changed' then host:showInfo(_('Cloud reading chapter changed during download. Please try again.'))
        elseif reason=='source_changed' or reason=='source_unavailable' then
            host:showInfo(_('This file has no matching original text. Download the target chapter or full book and try again.'))
        elseif job.navigating or job.switching then host:showInfo(_('Could not locate the cloud position in this file. Please check the current page.'))
        else host:showInfo(_('Could not verify the cloud reading position. Your current location is kept.')) end
    end
    if not host.cloud_source_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=65536} end)
        if not ok then finish('worker_unavailable');return false end
        host.cloud_source_worker=worker
    end
    local input={file=job.file,identity=identity,book_id=id,request_id=job.sequence}
    local handle
    local function run(task)
        local ok,started=pcall(host.cloud_source_worker.start,host.cloud_source_worker,function()
            local valid,result=pcall(task)
            return valid and result or {error='cloud_unavailable',request_id=job.sequence}
        end,function(result)
            if not current(host,job) then if host.cloud_source_request==job then M.cancel(host) end return end
            handle(result)
        end)
        if not ok or not started then finish('worker_unavailable');return false end
        return true
    end
    local function download(result)
        local confirm
        close_busy(host,job)
        confirm=require('ui/widget/confirmbox'):new{
            keep_dialog_open=true,
            text=require('ffi/util').template(_('Cloud position is in "%1". No matching downloaded file is available.\n\nDownload this chapter and open the verified position?'),
                require('weread.lib.protocol').utf8_substr(result.chapter.title or '',80)),
            ok_text=_('Download target chapter'),cancel_text=_('Cancel'),
            cancel_callback=function()
                if host.cloud_source_request==job and job.confirm==confirm then
                    -- ConfirmBox closes itself after cancel/back; do not close twice.
                    job.confirm=nil;M.cancel(host)
                end
            end,
            ok_callback=function()
                if not current(host,job) then if host.cloud_source_request==job then M.cancel(host) end return end
                UIManager:close(confirm);job.confirm=nil
                local downloader=host.downloader
                if not downloader or downloader._active_job or downloader._scheduled_start or downloader._pending_start then
                    finish('download_unavailable');return
                end
                job.started,job.downloading=os.time(),true
                local saved=host.settings.get_book and host.settings:get_book(id) or {book_id=id,title=''}
                saved=saved or {book_id=id,title=''}
                local ok,started=pcall(downloader.start,downloader,saved,{result.chapter},'chapter',{
                    single_chapter=true,silent_completion=true,offer_read=false,
                    on_complete=function(success,path)
                        if not current(host,job) then if host.cloud_source_request==job then M.cancel(host) end return end
                        job.download=nil
                        if not success then
                            if path=='cancelled' then M.cancel(host) else finish('download_unavailable') end
                            return
                        end
                        job.task=function()
                            job.task=nil
                            if not current(host,job) then if host.cloud_source_request==job then M.cancel(host) end return end
                            job.downloading,job.started=false,os.time()
                            busy()
                            run(function()
                                local fresh=Cloud.fetch(host.client,id,access)
                                if fresh.chapter_uid~=result.remote.chapter_uid then return {error='cloud_changed',request_id=job.sequence} end
                                local bound=Cloud.bind_file(path,fresh,job.sequence)
                                bound.remote=fresh;bound.request_id=job.sequence
                                return bound
                            end)
                        end
                        UIManager:scheduleIn(0.1,job.task)
                    end,
                })
                if host.cloud_source_request==job then job.download=downloader._active_job end
                if not ok or not started then finish('download_unavailable') end
            end,
        }
        job.confirm=confirm
        UIManager:show(confirm)
    end
    handle=function(result)
        if type(result)~='table' or result.request_id~=job.sequence then finish('target_unavailable');return end
        local position=result.position
        if position and result.file and result.file~=job.file and not resume then
            local transfer=Handoff.prepare(host,job,result.file,result.identity,result.remote,function(next_host,selected_remote,file_id,selected_access)
                return receive(next_host,selected_remote,file_id,selected_access,job.sync_choice)
            end)
            if not transfer then finish('source_changed');return end
            job.switching=true
            M.cancel(host)
            local called=pcall(host.openFile,host,result.file,transfer)
            if not called then host:showInfo(_('Could not locate the cloud position in this file. Please check the current page.')) end
            return
        end
        if not position and not resume and not job.downloading and not job.download_attempted
            and result.chapter and Cloud.remote(result.remote) then
            job.download_attempted=true;download(result);return
        end
        local snapshot=type(position)=='table' and Source.document_metadata(document,id,position.chapter_uid,position.render_path)
        if not snapshot or snapshot.metadata~=result.metadata then finish(result.error or 'target_unavailable');return end
        job.dispatching,job.navigating,job.started=true,true,os.time()
        local called,opened=pcall(host.openSourcePosition,host,position,function(applied,reason)
            if not current(host,job,true) then if host.cloud_source_request==job then M.cancel(host) end return end
            if applied and host.progress_sync then
                local saved,accepted=pcall(host.progress_sync.accept_cloud_source_target,host.progress_sync,applied,job.sync_choice,result.remote)
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
    end
    busy()
    return run(function()
        if resume then return Cloud.bind(input,remote) end
        return Cloud.resolve(host.client,input,Cloud.fetch(host.client,id,access),access)
    end)
end
return M
