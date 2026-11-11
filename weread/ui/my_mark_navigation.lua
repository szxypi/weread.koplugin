-- Explicit personal-highlight navigation. All source/archive/catalog work is
-- outside the UI process; only its scoped result can open a native document.
local Target=require('weread.lib.my_mark_target')
local Context=require('weread.lib.source_context')
local WorkerSettings=require('weread.lib.worker_settings')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function close_busy(host,job)
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
    job.busy=nil
end
function M.cancel(host,owner)
    local job=owner.navigation;owner.navigation=nil
    if not job then return end
    if job.worker then job.worker:cancel() end
    if job.task then UI:unschedule(job.task) end
    local confirm=job.confirm;job.confirm=nil
    if confirm then UI:close(confirm) end
    if job.download and host.downloader then host.downloader:cancelJob(job.download,'cancelled') end
    close_busy(host,job)
end
local function owner_key(host) return host.library_db and host.library_db:accountKey() end
local function reader_location(host)
    local doc=host.ui and host.ui.document
    return doc and Context.location(doc,host.ui.view and host.ui.view.view_mode or 'page')
end
local function open_bound(host,owner,job,result,current)
    if not current() then return end
    local scope,account=owner.scope,owner.account
    local document,session=host.ui and host.ui.document,host._reader_session_gen or 0
    local navigation=host.progress_sync and host.progress_sync.navigation_generation
    local old_sync=host.progress_sync
    local departure_navigation,departure_generation,departure_account
    local started=os.time();local used=false
    local function receive(reader)
        if used then return false end
        used=true
        local next_host=reader and reader.weread
        local doc=next_host and next_host.ui and next_host.ui.document
        local elapsed=os.time()-started
        if elapsed<0 or elapsed>120 or not next_host or not doc or doc~=reader.document or doc.file~=result.file
            or owner_key(host)~=account or owner_key(next_host)~=account
            or not host.settings:auth_scope_matches(scope) or not next_host.settings:auth_scope_matches(scope)
            or tostring(next_host:detectWeReadBook() or '')~=owner.id or not next_host.progress_sync or not next_host.source_navigation
            or not (next_host==host and doc==document and (host._reader_session_gen or 0)==session
                and host.progress_sync.navigation_generation==navigation
                or next_host~=host and (host._reader_session_gen or 0)==session+(document and 1 or 0)
                    and next_host.progress_sync.navigation_generation==0
                    and (not old_sync or old_sync.navigation_generation==departure_navigation
                        and (departure_generation==nil or old_sync.generation==departure_generation+(document and 1 or 0))
                        and old_sync.account_generation==departure_account)) then return false end
        local sync=next_host.progress_sync
        local ok,frame=pcall(sync.begin_file_resume,sync)
        if not ok or not frame then
            next_host:showInfo(_('Reading position is temporarily unavailable. Please try again shortly.'));return false
        end
        local active={frame=frame};next_host._read_resume_active=active
        local called,opened=pcall(next_host.openSourcePosition,next_host,result.position,function(applied)
            if next_host._read_resume_active~=active then return end
            next_host._read_resume_active=nil
            local saved,accepted=pcall(sync.finish_file_resume,sync,frame,applied~=nil)
            if not saved or not accepted then
                next_host:showInfo(_('Reading position opened, but it could not be saved. Check storage before continuing.'))
            elseif not applied then
                next_host:showInfo(_('Could not locate this highlight in the original text. Try downloading the chapter again.'))
            end
        end)
        if not called or not opened then
            if next_host._read_resume_active==active then next_host._read_resume_active=nil end
            pcall(sync.finish_file_resume,sync,frame,false)
            next_host:showInfo(_('Could not locate this highlight in the original text. Try downloading the chapter again.'))
            return false
        end
        if next_host._read_resume_active==active then active.job=next_host.source_navigation.job end
        return true
    end
    -- Stop the lookup before closing the menu: its normal close hook may cancel
    -- late work, but cannot cancel this one-use, independently guarded handoff.
    owner.navigation=nil;close_busy(host,job)
    if document and document.file==result.file then
        host:closeWeReadUI();receive(host.ui)
    else
        if old_sync then
            local prepared=pcall(old_sync.begin_file_resume_departure,old_sync)
            if not prepared then host:showInfo(_('Reading position is temporarily unavailable. Please try again shortly.'));return end
            departure_navigation,departure_generation,departure_account=old_sync.navigation_generation,old_sync.generation,old_sync.account_generation
        end
        host:openFile(result.file,receive)
    end
end
function M.start(host,owner,row,is_current)
    M.cancel(host,owner)
    if owner.thoughts or not Target.can_locate(row) then return false end
    if host.read_report and host.read_report.job then
        host:showInfo(_('Reading position is temporarily unavailable. Please try again shortly.'));return false
    end
    local original=owner.value
    local job={started=os.time(),location=reader_location(host),row={type=1,chapterUid=row.chapterUid,markText=row.markText,range=row.range},request_id=1}
    owner.navigation=job
    local function current()
        local age=os.time()-job.started
        local at=reader_location(host)
        return owner.navigation==job and is_current(host,owner) and owner.value==original and age>=0
            and age<=(job.downloading and 1800 or 120)
            and (not host.ui.document and not job.location or Context.same_location(job.location,at))
    end
    local function fail()
        if owner.navigation~=job then return end
        if not current() then M.cancel(host,owner);return end
        M.cancel(host,owner)
        host:showInfo(_('Could not locate this highlight in the original text. Try downloading the chapter again.'))
    end
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=4*1024*1024} end)
    if not ok then fail();return false end
    job.worker=worker
    local book=host.settings:get_book(owner.id) or {book_id=owner.id,title=''}
    local function busy()
        host:showBusy(_('Locating saved highlight…'),function() if owner.navigation==job then M.cancel(host,owner) end end)
        job.busy=host.busy_message
    end
    local launch,handle
    local function run(task,done)
        local called,started=pcall(worker.start,worker,task,function(result)
            if not current() then if owner.navigation==job then M.cancel(host,owner) end;return end
            done(result)
        end)
        if not called or not started then fail();return false end
        return true
    end
    local function download()
        if not current() then return end
        if not host:isNetworkOnline() or not host:requireLogin(true,false) then fail();return end
        local Content=require('weread.lib.content')
        local Reading=require('weread.ui.book_reading')
        local fingerprint=WorkerSettings.fingerprint(host.settings)
        busy()
        run(function()
            local auth=WorkerSettings.capture(host.settings)
            local copy={book_id=owner.id,title=book.title,author=book.author,reader_url=book.reader_url}
            Content.ensure_reader_state(host.client,copy)
            return {book_id=owner.id,chapters=Reading.catalog(Content.fetch_catalog(host.client,copy)),auth=auth()}
        end,function(result)
            if WorkerSettings.fingerprint(host.settings)~=fingerprint then fail();return end
            local chapters=type(result)=='table' and result.book_id==owner.id and Reading.catalog(result.chapters)
            if not chapters or result.auth and not WorkerSettings.merge(host.settings,fingerprint,result.auth) then fail();return end
            local chapter
            for _i,item in ipairs(chapters) do
                if tostring(item.chapterUid)==tostring(job.row.chapterUid) then
                    if chapter then fail();return end
                    chapter=item
                end
            end
            if not chapter or not current() then fail();return end
            book=host.settings:get_book(owner.id) or book;book.chapters=chapters
            local saved,persisted=pcall(function()
                return host.library_db:putChapters(owner.id,chapters) and Content.save_catalog_cache(host.client,host.settings,book,chapters)
            end)
            if not saved or not persisted then fail();return end
            close_busy(host,job);job.started,job.downloading=os.time(),true
            local called,accepted=pcall(host.downloader.start,host.downloader,book,{chapter},'chapter',{
                single_chapter=true,include_annotations=false,offer_read=false,silent_completion=true,
                on_complete=function(success,path)
                    if not current() then if owner.navigation==job then M.cancel(host,owner) end;return end
                    job.download=nil
                    if not success then fail();return end
                    job.task=function()
                        job.task=nil
                        if not current() then if owner.navigation==job then M.cancel(host,owner) end;return end
                        job.started,job.downloading=os.time(),false;busy();launch(path)
                    end
                    UI:scheduleIn(0.1,job.task)
                end})
            if owner.navigation==job then job.download=host.downloader._active_job end
            if not called or not accepted then fail() end
        end)
    end
    handle=function(result)
        if type(result)~='table' or result.request_id~=job.request_id then fail();return end
        if result.position and result.identity and result.file then open_bound(host,owner,job,result,current);return end
        if job.download_attempted or not host:isNetworkOnline() then fail();return end
        close_busy(host,job)
        local confirm
        confirm=require('ui/widget/confirmbox'):new{
            text=_('No matching downloaded chapter. Download it and locate this highlight?'),
            ok_text=_('Download target chapter'),cancel_text=_('Cancel'),keep_dialog_open=true,
            ok_callback=function()
                if not current() or job.confirm~=confirm then return end
                job.confirm=nil;UI:close(confirm);job.download_attempted=true;download()
            end,
            cancel_callback=function() if owner.navigation==job and job.confirm==confirm then job.confirm=nil;M.cancel(host,owner) end end}
        job.confirm=confirm;UI:show(confirm)
    end
    launch=function(file)
        return run(function()
            if file then return Target.bind_file(file,owner.id,job.row,job.request_id) end
            local doc=host.ui and host.ui.document
            local path=doc and tostring(host:detectWeReadBook() or '')==owner.id and doc.file or nil
            return Target.resolve(book,path,job.row,job.request_id)
        end,handle)
    end
    busy();return launch()
end
return M
