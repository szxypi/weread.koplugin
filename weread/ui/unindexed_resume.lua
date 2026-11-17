-- Verify a catalog-free chapter selection off the UI thread before opening it.
local Cache=require('weread.lib.cached_book_search')
local Hint=require('weread.lib.unindexed_resume')
local Scope=require('weread.ui.page_scope')
local Source=require('weread.lib.position_source')
local Content=require('weread.lib.content')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function account(host) return host.library_db and host.library_db:accountKey() end
local function epoch(host) return host.settings:get('auth_epoch',0) end
local function same(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for _i,key in ipairs({'schema','book_id','chapter_uid','file_id','raw_sha256','basis','owner','auth_epoch'}) do
        if a[key]~=b[key] then return false end
    end
    return true
end
local function no_catalog(host,book)
    if type(book.chapters)=='table' and #book.chapters>0 then return false end
    local id=book.book_id or book.bookId
    local rows=host.library_db and host.library_db:getChapters(id)
    if type(rows)=='table' and #rows>0 then return false end
    rows=Content.load_catalog_cache(host.client,host.settings,book)
    return type(rows)~='table' or #rows==0
end
function M.cancel(host)
    local job=host._unindexed_resume_job;host._unindexed_resume_job=nil
    if not job then return end
    if job.worker then job.worker:cancel() end
    local confirm=job.confirm;job.confirm=nil
    if confirm then UI:close(confirm) end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
function M.start(host,book,hint,path)
    M.cancel(host)
    local id=tostring(book.book_id or book.bookId or '')
    local owner=account(host);local auth_epoch=epoch(host)
    if not Hint.valid(hint,id,owner,auth_epoch) or type(path)~='string' or path=='' then return false end
    hint=Hint.make({book_id=hint.book_id,chapter_uid=hint.chapter_uid,file_id=hint.file_id,
        raw_sha256=hint.raw_sha256,basis=hint.basis,upload_verified=false},id,owner,auth_epoch)
    local scope=Scope.capture(host,host.shelf_view)
    local auth=host.settings:get_auth_scope()
    local job={id=id,hint=hint,path=path,owner=owner,auth=auth,auth_epoch=auth_epoch,
        document=host.ui and host.ui.document,session=host._reader_session_gen or 0,started=os.time()}
    local function same_auth(candidate)
        if account(candidate)~=owner or epoch(candidate)~=auth_epoch then return false end
        local current=candidate.settings:get_auth_scope()
        if not auth then return current==nil end
        return current and candidate.settings:auth_scope_matches(auth)
    end
    local function current()
        local age=os.time()-job.started
        if host._unindexed_resume_job~=job or age<0 or age>120 or not scope() or not same_auth(host) then return false end
        local latest=host.settings:get_book(id)
        local mapped=type(latest)=='table' and type(latest.cached_chapters)=='table'
            and (latest.cached_chapters[hint.chapter_uid] or latest.cached_chapters[tonumber(hint.chapter_uid)])
        return latest and Hint.valid(latest.unindexed_resume,id,owner,auth_epoch)
            and same(latest.unindexed_resume,hint) and mapped==path and no_catalog(host,latest)
    end
    local ok,worker=pcall(function()
        return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=65536}
    end)
    if not ok or not worker then return false end
    job.worker=worker;host._unindexed_resume_job=job
    host:showBusy(_('Checking downloaded chapter…'),function() if host._unindexed_resume_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    local started,accepted=pcall(worker.start,worker,function()
        local snapshot=Cache.snapshot(path,id,hint.chapter_uid)
        if not snapshot or snapshot.identity.file_id~=hint.file_id or snapshot.record.raw_sha256~=hint.raw_sha256
            or Source.coordinate_basis(snapshot.record.format)~=hint.basis then return {valid=false} end
        return {valid=true}
    end,function(result)
        if not current() then if host._unindexed_resume_job==job then M.cancel(host) end;return end
        if type(result)~='table' or result.valid~=true then
            if job.busy and host.busy_message==job.busy then host:closeBusy() end
            job.busy=nil
            local dialog
            dialog=require('ui/widget/confirmbox'):new{
                text=_('Could not verify the saved chapter. Open the previous reading position instead?'),
                ok_text=_('Open previous position'),cancel_text=_('Cancel'),
                ok_callback=function()
                    if not current() or job.confirm~=dialog then return end
                    local latest=host.settings:get_book(id);local view=host._book_detail_view
                    M.cancel(host)
                    local opened,reason,uid=host:openBookForReading(latest,true,{prefer_exact=true,skip_unindexed_resume=true})
                    if not opened and reason=='resume_not_cached' then
                        require('weread.ui.missing_resume').show(host,id,view,uid)
                    elseif not opened then host:showInfo(_('No cached file.')) end
                end,
                cancel_callback=function() if current() and job.confirm==dialog then M.cancel(host) end end,
            }
            local closed=dialog.onCloseWidget
            dialog.onCloseWidget=function(instance,...)
                if host._unindexed_resume_job==job and job.confirm==instance then
                    job.confirm=nil;M.cancel(host)
                end
                if closed then return closed(instance,...) end
            end
            job.confirm=dialog;UI:show(dialog)
            return
        end
        M.cancel(host)
        local used=false
        host:openFile(path,function(reader)
            if used then return false end;used=true
            local next_host=reader and reader.weread
            local document=reader and reader.document
            if not next_host or not document or not next_host.ui or document~=next_host.ui.document or document.file~=path
                or not same_auth(host) or not same_auth(next_host)
                or (host._reader_session_gen or 0)~=job.session+(job.document and 1 or 0)
                or tostring(next_host:detectWeReadBook() or '')~=id or not next_host.progress_sync
                or next_host.progress_sync.navigation_generation~=0 or next_host.progress_sync.pending_jump
                or next_host.progress_sync.verified or next_host.cloud_source_request then return false end
            local snapshot=Source.document_metadata(document,id,hint.chapter_uid)
            if not snapshot or snapshot.identity.file_id~=hint.file_id or snapshot.record.raw_sha256~=hint.raw_sha256
                or Source.coordinate_basis(snapshot.record.format)~=hint.basis then
                next_host:showInfo(_('Could not verify the saved chapter. Search downloaded chapters again or choose another chapter.'))
                return false
            end
            local began,frame=pcall(next_host.progress_sync.begin_file_resume,next_host.progress_sync,{allow_missing_catalog=true})
            if not began or not frame then
                next_host:showInfo(_('Reading position is temporarily unavailable. Please try again shortly.'));return false
            end
            -- A catalog that appeared during open leaves the old intent protected
            -- by the normal failed-resume guard until explicit reader movement.
            local finished,accepted_frame=pcall(next_host.progress_sync.finish_file_resume,next_host.progress_sync,frame,false)
            if not finished or not accepted_frame then return false end
            return true
        end)
    end)
    if not started or not accepted then M.cancel(host);return false end
    return true
end
return M
