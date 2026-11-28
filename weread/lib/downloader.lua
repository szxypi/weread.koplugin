-- Book/chapter download engine.
--
-- Extracted from main.lua as an independent, dependency-injected object so the
-- plugin entry point keeps only thin menu wrappers. The host injects the API
-- client, settings, and a small set of UI/framework callbacks; the engine owns
-- the whole async download state machine and the device standby guard.
--
-- Standby guard: long downloads must not let the device suspend mid-transfer.
-- Every scheduled step runs through _scheduleGuarded, which wraps the step in
-- xpcall and always releases the guard (and closes the dialog + reports the
-- error) if the step throws. This is critical: a bare UIManager:scheduleIn that
-- threw would leak the guard and leave the device unable to sleep until reboot.

local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")
local time = require("ui/time")
local T = require("ffi/util").template

local Content = require("weread.lib.content")
local FileIdentity = require("weread.lib.book_file_identity")
local DownloadDialog = require("weread.ui.download_dialog")
local Footnotes = require("weread.lib.footnotes")
local I18n = require("weread.lib.i18n")
local ReadAccess = require("weread.lib.read_access")
local StandbyGuard = require("weread.lib.standby_guard")
local WeRead = require("weread.lib.protocol")
local WorkerSettings = require("weread.lib.worker_settings")
local DownloadReadClient = require("weread.lib.download_read_client")

local function _(text)
    return I18n.tr(text)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function rate_limited(err)
    return type(err) == "string" and (err == "download_read/rate_limited"
        or err:match("^download_read/rate_limited[\r\n]") ~= nil)
end

local READER_BOOK_FIELDS = {
    "book_id", "title", "author", "psvts", "pclts", "token", "reader_url",
    "chapter_uid", "chapter_idx", "chapter_offset", "progress", "summary",
    "_content_format", "cache_dir", "bookVersion",
}

local function reader_book(book)
    local snapshot = {}
    for _, key in ipairs(READER_BOOK_FIELDS) do snapshot[key] = book[key] end
    return snapshot
end

local function apply_reader_book(book, updated)
    -- Include nil values when a fresh reader session drops old credentials.
    for _, key in ipairs(READER_BOOK_FIELDS) do book[key] = updated[key] end
end

local Downloader = {}
Downloader.__index = Downloader
local RESUME_SKIP_BATCH_SIZE = 25

-- o = {
--   client, settings,                       -- injected dependencies
--   show_info(text), show_transient(text, timeout),
--   refresh_ui(), refresh_shelf(),
--   open_file(path), safe_callback(label, fn),
--   require_login(cookie, api_key), run_online_task(label, fn),
--   background_worker,                         -- host framework
-- }
function Downloader:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

function Downloader:recover()
    -- A SIGKILL/OOM cannot run the normal finally path. A fresh plugin process
    -- owns no active download, so it is safe to clear the persistent Kindle
    -- powerd flag and remove disk artifacts left by the previous process.
    StandbyGuard.recover()
    local ok, removed = pcall(Content.cleanup_stale_downloads, self.settings)
    if not ok then
        logger.warn("stale download recovery failed:", log_error(removed))
        return false
    end
    if tonumber(removed) and removed > 0 then
        logger.info("stale download artifacts removed:", tostring(removed))
    end
    return true
end

function Downloader:_cleanupWorkspace(dl)
    if not dl or not dl.workspace then return end
    local workspace = dl.workspace
    dl.workspace = nil
    if dl.state then dl.state.workspace = nil end
    Content.cleanup_download_workspace(workspace)
end

-- A resumable full-book workspace is intentionally retained after a failure,
-- cancellation or crash.  It only contains downloaded book material under the
-- cache directory; credentials and settings remain untouched.
function Downloader:_preserveWorkspace(dl, reason)
    self:_releaseStandby(dl)
    if dl and dl.progress_dialog then
        dl.progress_dialog:close()
        dl.progress_dialog = nil
    end
    logger.info("full-book download checkpoint retained:",
        "reason=", tostring(reason or "paused"),
        "completed=", tostring(dl and dl.completed_count or 0),
        "total=", tostring(dl and dl.total or 0))
    self:_notifyCompletion(dl, false, reason or "paused")
    self:_finishJob(dl)
end

function Downloader:_chapterStagingFailed(dl, reason)
    logger.warn("selected chapter workspace failed:", log_error(reason))
    self:_releaseStandby(dl)
    if dl.progress_dialog then
        dl.progress_dialog:close()
        dl.progress_dialog = nil
    end
    self:_cleanupWorkspace(dl)
    self:_notifyCompletion(dl, false, "download_cache_unavailable")
    self:_finishJob(dl)
    self.show_info(_("Could not save the downloaded chapters. Check storage and try again."))
end

function Downloader:_restoreFullDownloadCheckpoint(dl, initial)
    local completed = self:_runInterruptible(dl, function()
        return Content.full_download_completed_chapters(
            dl.workspace, dl.chapters, initial and dl.source_identity and dl.source_identity.book_version or nil,
            self.settings:get('cache',{}).download_book_images==true)
    end)
    if dl.cancelled then return 0 end
    -- A missing, legacy or damaged shared stylesheet needs a fresh Web
    -- source. Re-fetch one chapter while keeping all other valid checkpoints.
    if initial and dl.state.css == nil and #dl.chapters > 0 then
        local all_completed = true
        for index = 1, #dl.chapters do
            if not completed[index] then all_completed = false; break end
        end
        if all_completed then completed[1] = nil end
    end
    local selected = {}
    local completed_count = 0
    for chapter_index, chapter in ipairs(dl.chapters) do
        if completed[chapter_index] then
            table.insert(selected, chapter)
            completed_count = completed_count + 1
        end
    end
    dl.completed = completed
    dl.selected = selected
    dl.completed_count = completed_count
    return completed_count
end

-- Keep the device awake during long book downloads (reference counted so
-- multiple concurrent jobs share a single guard).
function Downloader:_beginStandby()
    self._standby_ref = (self._standby_ref or 0) + 1
    if self._standby_ref == 1 then
        self._standby_token = StandbyGuard.acquire()
    end
end

function Downloader:_endStandby()
    local ref = self._standby_ref or 0
    if ref <= 0 then
        return
    end
    self._standby_ref = ref - 1
    if self._standby_ref == 0 then
        StandbyGuard.release(self._standby_token)
        self._standby_token = nil
    end
end

function Downloader:_releaseStandby(dl)
    if dl and dl.standby_guard then
        dl.standby_guard = nil
        self:_endStandby()
    end
end

function Downloader:_notifyCompletion(dl, ok, value)
    if not dl or dl.completion_notified then return end
    dl.completion_notified = true
    if type(dl.on_complete) ~= "function" then return end
    local called, err = pcall(dl.on_complete, ok == true, value)
    if not called then
        logger.warn("download completion callback failed:",
            log_error(err))
    end
end

function Downloader:_finishJob(dl)
    if dl.operation_lease then dl.operation_lease:release();dl.operation_lease=nil end
    if self._active_job == dl then
        self._active_job = nil
    end
    local pending = self._pending_start
    if pending and not self._active_job then
        self._pending_start = nil
        local scheduled = { pending = pending }
        self._scheduled_start = scheduled
        UIManager:scheduleIn(0.1, function()
            if self._scheduled_start ~= scheduled then return end
            self._scheduled_start = nil
            self:start(pending.book, pending.chapters, pending.suffix, pending.options)
        end)
    end
end

function Downloader:_cancelScheduledPrefetch(reason)
    local scheduled = self._scheduled_start
    local pending = scheduled and scheduled.pending
    if not pending or not pending.options or not pending.options.prefetch then
        return false
    end
    self._scheduled_start = nil
    local book = pending.book or {}
    local chapter = pending.chapters and pending.chapters[1] or {}
    logger.info("scheduled prefetch cancelled:",
        "book_id=", tostring(book.book_id or book.bookId or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(reason or "cancelled"))
    return true
end

function Downloader:getActivePrefetch()
    local job = self._active_job
    if job and job.prefetch and not job.cancelled then
        return job
    end
end

function Downloader:cancelPrefetch(reason)
    local cancelled_scheduled = self:_cancelScheduledPrefetch(reason)
    local cancelled_pending = false
    if self._pending_start and self._pending_start.options
        and self._pending_start.options.prefetch then
        local pending = self._pending_start
        local pending_book = pending.book or {}
        local pending_chapter = pending.chapters and pending.chapters[1] or {}
        logger.info("pending prefetch cancelled:",
            "book_id=", tostring(pending_book.book_id or pending_book.bookId or ""),
            "chapter_uid=", tostring(pending_chapter.chapterUid
                or pending_chapter.chapterId or ""),
            "reason=", tostring(reason or "cancelled"))
        self._pending_start = nil
        cancelled_pending = true
    end
    local job = self:getActivePrefetch()
    if not job then return cancelled_scheduled or cancelled_pending end
    job.cancelled = true
    job.cancel_reason = reason or "cancelled"
    if job.worker_handle and self.background_worker then
        self.background_worker:cancel(job.worker_handle, job.cancel_reason)
    end
    local chapter = job.chapters and job.chapters[1] or {}
    logger.info("active prefetch cancelled:",
        "book_id=", tostring(job.book
            and (job.book.book_id or job.book.bookId) or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(job.cancel_reason))
    if job.progress_dialog then
        job.progress_dialog:close()
        job.progress_dialog = nil
    end
    return true
end

function Downloader:isPrefetching(book, chapter)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    return job ~= nil
        and tostring(job_book_id or "") == tostring(book_id or "")
        and tostring(target_uid or "") == tostring(chapter_uid or "")
end

local function chapter_open_current(guard)
    if guard==nil then return true end
    local ok,current=pcall(guard)
    return ok and current==true
end

local function promotion_current(job)
    return job~=nil and chapter_open_current(job.promotion_current)
end

function Downloader:promotePrefetch(book, chapter, is_current)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    if tostring(job_book_id or "") ~= tostring(book_id or "")
        or tostring(target_uid or "") ~= tostring(chapter_uid or "") then
        return false
    end
    job.open_on_complete = true
    job.promoted = true
    job.promotion_current = is_current
    self:_ensureProgressDialog(job)
    return true
end

function Downloader:isPromotedPrefetch(book, chapter)
    local job=self._active_job
    if self:isPrefetching(book, chapter) and job.promoted==true and promotion_current(job) then
        return true,job.promotion_current
    end
    return false
end

-- Revoke a caller's queued or active foreground request without touching others.
function Downloader:cancelRequest(on_complete, reason)
    local pending = self._pending_start
    if pending and pending.options.on_complete == on_complete then
        self._pending_start = nil
    end
    local scheduled = self._scheduled_start
    if scheduled and scheduled.pending.options.on_complete == on_complete then
        self._scheduled_start = nil
    end
    local active = self._active_job
    if active and active.on_complete == on_complete then return self:cancelJob(active, reason) end
    return pending ~= self._pending_start or scheduled ~= self._scheduled_start
end

-- Cancel only the supplied foreground job, including its suspended child.
function Downloader:cancelJob(dl,reason)
    if not dl or self._active_job~=dl or dl.prefetch or dl.cancelled then return false end
    local dialog=dl.progress_dialog
    local dismiss=dialog and dialog.dismiss_callback
    dl.cancelled,dl.cancel_reason=true,reason or "cancelled"
    if dialog then dialog:close();dl.progress_dialog=nil end
    if dismiss then dismiss() end
    return true
end

function Downloader:_ensureProgressDialog(dl)
    if dl.progress_dialog then return dl.progress_dialog end
    local progress_dialog = DownloadDialog:new{
        title = dl.stage_title or T(_("Downloading: %1"), dl.book.title or ""),
        description = dl.resumable and _("You can cancel at any time. Completed chapters are kept.\nChoose Download full book again to resume.") or nil,
        progress_max = dl.total,
        buttons = {{
            {
                text = _("Cancel download"),
                callback = function()
                    if not dl.prefetch then self:cancelJob(dl,"cancelled");return end
                    local dismiss = dl.progress_dialog and dl.progress_dialog.dismiss_callback
                    self:cancelPrefetch("cancelled")
                    if dl.progress_dialog then
                        dl.progress_dialog:close()
                        dl.progress_dialog = nil
                    end
                    -- Trapper resumes the suspended download and kills its child.
                    if dismiss then dismiss() end
                end,
            },
        }},
    }
    dl.progress_dialog = progress_dialog
    progress_dialog:show()
    if dl.stage_progress then
        progress_dialog:reportProgress(dl.stage_progress)
    end
    self.refresh_ui()
    return progress_dialog
end

local function file_exists(path)
    if not path then return false end
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

function Downloader:_prefetchStage(dl, state)
    local stage = state and state.stage
    local title
    if stage == "reader" then
        title = T(_("Preparing chapter %1/%2"), "1", "1")
    elseif stage == "source" then
        local attempt = tonumber(state.attempt) or 1
        if attempt > 1 then
            title = T(_("Retrying chapter %1/%2 · attempt %3"), "1", "1",
                tostring(attempt - 1))
        else
            local chapter = dl.chapters[1] or {}
            title = T(_("Downloading chapter %1/%2: %3"), "1", "1",
                chapter.title or tostring(chapter.chapterUid or ""))
        end
    elseif stage == "images" then
        title = T(_("Downloading images · chapter %1/%2"), "1", "1")
    elseif stage == "footnotes" then
        title = T(_("Processing footnotes · chapter %1/%2"), "1", "1")
    elseif stage == "epub" then
        title = _("Building EPUB...")
    else
        title = T(_("Processing chapter %1/%2"), "1", "1")
    end
    self:_setStage(dl, title, stage == "epub" and 1 or 0)
end

local function full_scope_current(settings,dl)
    return not dl.full_auth_scope or settings.auth_scope_matches and settings:auth_scope_matches(dl.full_auth_scope)
end

local function prefetch_current(settings,dl)
    if dl.native_chapter_resources then
        local cache=settings:get('cache',{})
        if cache.native_chapter_resources~=true or cache.download_book_images~=true then return false,'setting_disabled' end
    end
    return (not dl.auth_scope or settings:auth_scope_matches(dl.auth_scope)
        and WorkerSettings.fingerprint(settings)==dl.auth_fingerprint)
        and (not dl.native_chapter_resources
            or require('weread.lib.native_read_access').matches(settings,dl.native_selected))
end

function Downloader:_recordDownload(dl, book_id, change, first_record)
    local called, ok, record = pcall(self.settings.record_download, self.settings, book_id, first_record or dl.book, change)
    if not called or not ok then
        local reason = called and record or ok
        logger.warn("save download metadata failed:", log_error(reason))
        return false, reason == "book_identity_conflict" and reason or "download_cache_unavailable"
    end
    local book = dl.book
    book.cache_dir = record.cache_dir
    book.cached_chapters = record.cached_chapters
    book.cached_file = record.cached_file
    book.cached_full_book = record.cached_full_book
    book.annotation_documents = record.annotation_documents
    book.reader_url = book.reader_url or change.reader_url
    return true
end

function Downloader:_applyPrefetchResult(dl, result)
    self:_releaseStandby(dl)
    dl.worker_handle = nil
    if dl.progress_dialog then
        dl.progress_dialog:close()
        dl.progress_dialog = nil
    end
    if self._active_job ~= dl then return end
    if dl.cancelled then
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        return
    end
    local current,current_reason=prefetch_current(self.settings,dl)
    if not current then
        self:_notifyCompletion(dl,false,current_reason or 'account_changed')
        self:_finishJob(dl)
        return
    end
    if type(result) ~= "table" or result.ok ~= true
        or type(result.value) ~= "table" or not file_exists(result.value.path) then
        local reason = type(result) == "table" and result.error or "worker_no_result"
        if type(reason)=='string' and (reason=='book_reading/web_expired' or reason:match('^book_reading/web_expired[\r\n]')) then
            reason='web_expired'
        elseif rate_limited(reason) then reason='rate_limited'
        elseif type(reason)=='string' and (reason=='chapter_prefetch/session_changed'
            or reason:match('^chapter_prefetch/session_changed[\r\n]')
            or reason=='native_candidate/session_changed'
            or reason:match('^native_candidate/session_changed[\r\n]')) then reason='account_changed'
        elseif type(reason)=='string' and (reason=='native_candidate/auth_expired'
            or reason:match('^native_candidate/auth_expired[\r\n]')) then reason='native_auth_expired'
        elseif type(reason)=='string' and reason:match('^native_candidate/') then reason='native_resource_failed' end
        self:_notifyCompletion(dl, false, reason)
        self:_finishJob(dl)
        return
    end

    local value = result.value
    local book_id = tostring(dl.book.book_id or dl.book.bookId or "")
    local chapter = dl.chapters[1] or {}
    local uid = tostring(chapter.chapterUid or chapter.chapterId or "1")
    if type(dl.prefetch_book_id)~='string' or dl.prefetch_book_id=='' or book_id~=dl.prefetch_book_id
        or type(dl.prefetch_chapter_uid)~='string' or uid~=dl.prefetch_chapter_uid
        or value.book_id~=dl.prefetch_book_id or value.chapter_uid~=dl.prefetch_chapter_uid
        or not ReadAccess.cached_book({[book_id]=dl.book},book_id) then
        self:_notifyCompletion(dl,false,'book_identity_conflict')
        self:_finishJob(dl)
        return
    end
    local saved, reason = self:_recordDownload(dl, book_id, {
        cached_chapters = { [uid] = value.path },
        annotation_documents = value.annotation_document and { [value.path] = value.annotation_document },
        cache_dir = value.cache_dir,
        reader_url = value.reader_url,
    }, { book_id = book_id })
    if not saved then
        self:_notifyCompletion(dl, false, reason)
        self:_finishJob(dl)
        return
    end
    if value.auth and not WorkerSettings.merge(self.settings,
        dl.auth_fingerprint, value.auth) then
        logger.info("skip worker auth write-back: parent auth changed")
    end
    self.refresh_shelf()
    logger.info("prefetch worker completed:", "book_id=", book_id,
        "chapter_uid=", uid, "path=", value.path)
    self:_notifyCompletion(dl, true, value.path)
    self:_finishJob(dl)
    if dl.open_on_complete and promotion_current(dl) then self.open_file(value.path,dl.book) end
end

function Downloader:_startPrefetchWorker(dl)
    local worker = self.background_worker
    if not worker or not worker:available() then
        self:_applyPrefetchResult(dl, {
            ok = false, error = "worker_unavailable",
        })
        return false
    end
    local ChapterWorker = require("weread.lib.chapter_prefetch_worker")
    local ok, handle = worker:start {
        kind = "chapter",
        queue = true,
        replace_active = true,
        timeout = 180,
        task = function(context)
            return ChapterWorker.run(self.settings, self.client, dl.book,
                dl.chapters[1], context, dl.auth_scope, dl.auth_fingerprint,
                dl.native_chapter_resources and dl.native_selected.fingerprint or nil)
        end,
        on_launch = function(pid, available_kb)
            if self._active_job ~= dl then return end
            self:_beginStandby()
            dl.standby_guard = true
            logger.info("prefetch worker started:", "pid=", tostring(pid),
                "available_kb=", tostring(available_kb or "unknown"))
        end,
        on_progress = function(state)
            if self._active_job == dl then self:_prefetchStage(dl, state) end
        end,
        on_done = function(result)
            self:_applyPrefetchResult(dl, result)
        end,
    }
    if ok then
        dl.worker_handle = handle
        return true
    end
    return false
end

-- Network work, immutable raw-source staging and EPUB building run in the child.
-- Rendered completion checkpoints, settings and UI stay in the parent. Reuse
-- KOReader's pipe transport and cancellation/reaping.
function Downloader:_runInterruptible(dl, task)
    if dl.cancelled then return nil end
    local function scoped_client()
        if dl.detect_expired_login or dl.reading_auth_recovery then
            return require('weread.lib.book_reading_client').wrap(self.client,dl.book,dl.chapters[dl.index or 1])
        end
        return self.client
    end
    local function updated(before)
        if (dl.reading_auth_recovery or dl.full_auth_recovery or dl.manual_auth_recovery) and type(dl.on_reading_auth_updated)=='function' then
            local after=WorkerSettings.fingerprint(self.settings)
            if after~=before then pcall(dl.on_reading_auth_updated,before,after) end
        end
    end
    if not dl.trapper then
        if not dl.detect_expired_login and not dl.reading_auth_recovery then return task(self.client) end
        local before=WorkerSettings.fingerprint(self.settings)
        local ok,value=pcall(task,scoped_client())
        updated(before)
        if not ok then error(value,0) end
        return value
    end
    local dialog = dl.progress_dialog
    local fingerprint = WorkerSettings.fingerprint(self.settings)
    local completed, result = dl.trapper:dismissableRunInSubprocess(function()
        local auth_result = WorkerSettings.capture(self.settings)
        -- Match the independently verified read cadence for batches. The
        -- wrapper and its waits exist only in this disposable child, so the
        -- UI remains responsive and cancellation can terminate a waiting read.
        local base = scoped_client()
        local client = (tonumber(dl.total) or 0) > 1
            and DownloadReadClient.wrap(base) or base
        local ok, value = xpcall(function() return task(client) end, debug.traceback)
        return { ok = ok, value = value, auth = auth_result() }
    end, dialog)
    if dialog then dialog.dismiss_callback = nil end
    if dl.cancelled then return nil end
    if not completed then error("could not start download worker") end
    if not result then error("download worker returned no result") end
    if result.auth and (result.ok or not (dl.detect_expired_login or dl.reading_auth_recovery)) then
        local merged=WorkerSettings.merge(self.settings,fingerprint,result.auth)
        if merged then updated(fingerprint) end
    end
    if not result.ok then error(result.value, 0) end
    return result.value
end

-- Schedule any download step behind xpcall so an uncaught error always releases
-- the standby guard, closes the progress dialog, and reports the failure.
function Downloader:_scheduleGuarded(dl, step_fn, delay)
    UIManager:scheduleIn(delay or 0.1, function()
        local function run()
            local ok, err = xpcall(step_fn, debug.traceback)
            if not ok and dl.standby_guard then
                logger.err("download step failed:", log_error(err))
                if dl.resumable then
                    self:_preserveWorkspace(dl, err)
                else
                    self:_releaseStandby(dl)
                    self:_cleanupWorkspace(dl)
                    if dl.progress_dialog then
                        dl.progress_dialog:close()
                        dl.progress_dialog = nil
                    end
                    self:_notifyCompletion(dl, false, err)
                    self:_finishJob(dl)
                end
                if not dl.prefetch then
                    self.show_info(T(_("Download failed:\n%1"), display_error(err)))
                end
            end
        end
        if dl.trapper then dl.trapper:wrap(run) else run() end
    end)
end

-- Public entry: start downloading the given chapters as one EPUB.
function Downloader:start(book, chapters, suffix, options)
    options = options or {}
    chapters = type(chapters) == "table" and chapters or {}
    if not chapter_open_current(options.read_current) then
        if type(options.on_complete)=='function' then pcall(options.on_complete,false,'navigation_changed') end
        return false
    end
    if options.prefetch and self.is_connected and not self.is_connected() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "offline")
        end
        return false
    end
    if options.prefetch and self.settings.is_cookie_configured
        and not self.settings:is_cookie_configured() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end
    if not options.prefetch and not self.require_login(true, false) then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end

    local scheduled = self._scheduled_start
    if scheduled then
        local scheduled_prefetch = scheduled.pending
            and scheduled.pending.options
            and scheduled.pending.options.prefetch == true
        if scheduled_prefetch then
            self:_cancelScheduledPrefetch(
                options.prefetch and "replaced" or "manual_download")
        else
            if not options.prefetch then
                self.show_transient(_("Another download is already in progress."), 1)
            end
            return false
        end
    end

    local active = self._active_job
    if active then
        if options.prefetch then
            if active.prefetch then
                self:cancelPrefetch("replaced")
                self._pending_start = {
                    book = book,
                    chapters = chapters,
                    suffix = suffix,
                    options = options,
                }
                return true
            end
            return false
        end
        if active.prefetch then
            self:cancelPrefetch("manual_download")
            self._pending_start = {
                book = book,
                chapters = chapters,
                suffix = suffix,
                options = options,
            }
            return true
        end
        self.show_transient(_("Another download is already in progress."), 1)
        return false
    end

    local total = #chapters
    local resumable = (suffix or "book") == "full"
        and not options.single_chapter
        and not options.separate_chapters
    local dl = {
        book = book,
        chapters = chapters,
        suffix = suffix or "book",
        index = 1,
        cancelled = false,
        selected = {},
        bodies = {},
        position_sources = {},
        assets = {},
        assets_by_uid = {},
        state = {},
        total = total,
        failed = {},
        resumable = resumable,
        completed = {},
        completed_count = 0,
        annotation_failed_batches = 0,
        footnote_scans = {},
        footnote_stats = {
            candidates = 0,
            converted = 0,
            image_notes = 0,
            backlinks = 0,
            removed_note_blocks = 0,
            unresolved = 0,
            fallback = 0,
        },
        single_chapter = options.single_chapter == true,
        separate_chapters = options.separate_chapters == true and options.single_chapter ~= true,
        include_annotations = false,
        open_on_complete = options.open_on_complete == true,
        read_current = options.read_current,
        offer_read = options.offer_read ~= false,
        silent_completion = options.silent_completion == true,
        prefetch = options.prefetch == true,
        prefetch_book_id = options.prefetch and tostring(book.book_id or book.bookId or "") or nil,
        prefetch_chapter_uid = options.prefetch and tostring((chapters[1] or {}).chapterUid
            or (chapters[1] or {}).chapterId or "1") or nil,
        start_delay = tonumber(options.start_delay) or 0,
        on_start = options.on_start,
        on_complete = options.on_complete,
        started_at = time.now(),
        auth_fingerprint = WorkerSettings.fingerprint(self.settings),
        auth_scope = options.prefetch and self.settings.get_auth_scope and self.settings:get_auth_scope() or nil,
        full_auth_scope = resumable and self.settings.get_auth_scope and self.settings:get_auth_scope() or nil,
        reading_auth_recovery = options.reading_auth_recovery == true and options.single_chapter == true,
        full_auth_recovery = options.full_auth_recovery == true and resumable,
        manual_auth_recovery = options.manual_auth_recovery == true and options.prefetch ~= true,
        detect_expired_login = options.prefetch ~= true,
        on_reading_auth_updated = options.on_reading_auth_updated,
    }
    local download_cache = self.settings.get and self.settings:get('cache', {}) or {}
    dl.native_chapter_resources = download_cache.download_book_images == true
        and (dl.single_chapter and download_cache.native_chapter_resources == true
            or dl.resumable and download_cache.native_full_book_resources == true)
    if dl.native_chapter_resources then
        dl.native_selected = require('weread.lib.native_read_access').capture(self.settings)
        dl.native_chapter_resources = dl.native_selected ~= nil and not dl.native_selected.renewal_pending
    end
    self._active_job = dl

    if dl.prefetch and self.settings.get_auth_scope and (not dl.auth_scope
        or not self.settings:auth_scope_matches(dl.auth_scope)) then
        self:_notifyCompletion(dl,false,'account_changed');self:_finishJob(dl);return false
    end

    if self.operation_lock then
        local locked,lease,reason=pcall(self.operation_lock,book)
        if not locked or not lease and reason~='unsupported' then
            self:_notifyCompletion(dl,false,'cache_busy')
            self:_finishJob(dl)
            if not dl.prefetch then self.show_info(_('This book’s cache is being changed or cannot be locked. Try again after the other task finishes.')) end
            return false
        end
        dl.operation_lease=lease
    end

    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    local task_runner = function(callback)
        return self.run_online_task(task_label, callback)
    end
    local function notifyStart()
        if dl.start_notified or type(dl.on_start) ~= "function" then return end
        dl.start_notified = true
        local called, start_err = pcall(dl.on_start)
        if not called then
            logger.warn("download start callback failed:", log_error(start_err))
        end
    end
    if dl.prefetch then
        notifyStart()
        UIManager:scheduleIn(math.max(0.1, dl.start_delay), function()
            if self._active_job ~= dl then return end
            if dl.cancelled then
                self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
                self:_finishJob(dl)
                return
            end
            local current,current_reason=prefetch_current(self.settings,dl)
            if not current then
                self:_notifyCompletion(dl,false,current_reason or 'account_changed');self:_finishJob(dl);return
            end
            self:_startPrefetchWorker(dl)
        end)
        return true
    end
    local function initializeDownload()
        if dl.cancelled then
            self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
            self:_finishJob(dl)
            return
        end
        local ok_init, err_init = pcall(function()
            local prepared = options.prepared_reader
            local reader_checked = false
            if dl.reading_auth_recovery and total == 1 and type(prepared) == "table"
                and type(prepared.url) == "string" and prepared.fingerprint == dl.auth_fingerprint
                and prepared.fingerprint == WorkerSettings.fingerprint(self.settings) then
                local verified, url = pcall(require("weread.lib.reader_context").url, book)
                reader_checked = verified and url == prepared.url
            end
            if reader_checked then
                -- Chapter source loading still requests a fresh, chapter-specific session.
                book.title = book.title or prepared.title
                book.author = book.author or prepared.author
                book.reader_url = prepared.url
                book.psvts, book.pclts, book.token = nil, nil, nil
                require("weread.lib.reader_state").apply_to_book(book, prepared)
            else
                self:_setStage(dl, _("Connecting to WeRead..."))
                local updated = self:_runInterruptible(dl, function(client)
                    Content.ensure_reader_state(client, book)
                    return reader_book(book)
                end)
                if dl.cancelled then return end
                apply_reader_book(book, updated)
            end
            dl.source_identity = FileIdentity.capture(book)
            self:_setStage(dl, _("Preparing download..."))
            if dl.resumable and Content.open_full_download_workspace then
                dl.workspace = Content.open_full_download_workspace(
                    self.settings, book)
                dl.state.workspace = dl.workspace
                dl.state.css = Content.load_full_download_css(dl.workspace)
                dl.state.used_asset_names = Content.full_download_workspace_used_asset_names(
                    dl.workspace)
                self:_restoreFullDownloadCheckpoint(dl, true)
            elseif Content.create_download_workspace then
                dl.workspace = Content.create_download_workspace(
                    self.settings, book, dl.separate_chapters)
                dl.state.workspace = dl.workspace
            end
        end)
        if dl.cancelled then self:_step(dl); return end
        if not ok_init then
            logger.err("initialize book download failed:", log_error(err_init))
            self:_cleanupWorkspace(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            local expired = dl.detect_expired_login and type(err_init)=='string'
                and (err_init=='book_reading/web_expired' or err_init:match('^book_reading/web_expired[\r\n]'))
            if type(options.on_complete) == "function" then
                pcall(options.on_complete, false, expired and "web_expired" or rate_limited(err_init) and "rate_limited" or err_init)
            end
            dl.completion_notified = true
            self:_finishJob(dl)
            if not dl.prefetch and not (expired and (dl.reading_auth_recovery or dl.full_auth_recovery or dl.manual_auth_recovery)) then
                if expired then
                    self.show_info(_("WeRead login expired. Please sign in again and retry the download."))
                elseif rate_limited(err_init) then
                    self.show_info(_("WeRead is limiting requests. Download stopped. Please try again later."))
                else
                    self.show_info(T(_("Download failed:\n%1"), display_error(err_init)))
                end
            end
            return
        end

        self:_beginStandby()
        dl.standby_guard = true
        notifyStart()

        self:_scheduleGuarded(dl, function() self:_step(dl) end)
    end
    -- Paint before run_online_task checks connectivity (which may resolve DNS)
    -- and before initializeDownload opens the reader session or local cache.
    dl.stage_title = _("Checking network...")
    self:_ensureProgressDialog(dl)
    local ffiutil = require("ffi/util")
    if type(ffiutil.runInSubProcess) == "function" then
        local ok, trapper = pcall(require, "ui/trapper")
        if ok then dl.trapper = trapper end
    end
    local started = task_runner(function()
        if dl.trapper then dl.trapper:wrap(initializeDownload) else initializeDownload() end
    end)
    if started == false then
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_notifyCompletion(dl, false, "offline")
        self:_finishJob(dl)
    end
    return started ~= false
end

function Downloader:_setStage(dl, title, progress)
    dl.stage_title = title
    dl.stage_progress = progress
    if not dl.progress_dialog then return end
    dl.progress_dialog:setTitle(title)
    if progress then
        dl.progress_dialog:reportProgress(progress)
    end
end

function Downloader:_perf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info("download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

function Downloader:_failChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    table.insert(dl.failed, uid)
    if dl.footnote_scans then
        dl.footnote_scans[uid] = nil
    end
    logger.warn("chapter download failed:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_skipCompletedChapterBatch(dl)
    local first_index = dl.index
    local skipped = 0
    while dl.index <= dl.total and dl.completed[dl.index]
        and skipped < RESUME_SKIP_BATCH_SIZE do
        dl.index = dl.index + 1
        skipped = skipped + 1
    end
    if skipped == 0 then return false end
    self:_setStage(dl,
        T(_("Resuming downloaded chapter %1/%2"),
            tostring(dl.index - 1), tostring(dl.total)), dl.index - 1)
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    logger.info("resumed completed chapter batch:",
        "first=", tostring(first_index), "count=", tostring(skipped),
        "total=", tostring(dl.total))
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
    return true
end

function Downloader:_rateLimit(dl)
    if dl.resumable then
        self:_preserveWorkspace(dl, "rate_limited")
    else
        self:_releaseStandby(dl)
        self:_cleanupWorkspace(dl)
        if dl.progress_dialog then dl.progress_dialog:close();dl.progress_dialog = nil end
        self:_notifyCompletion(dl, false, "rate_limited")
        self:_finishJob(dl)
    end
    if not dl.prefetch then
        self.show_info(_(dl.resumable
            and "WeRead is limiting requests. Download paused; completed chapters are kept. Try Download full book again later."
            or "WeRead is limiting requests. Download stopped. Please try again later."))
    end
end

function Downloader:_retryChapterSource(dl, err)
    if (dl.detect_expired_login or dl.reading_auth_recovery) and type(err)=='string' and
        (err=='book_reading/web_expired' or err:match('^book_reading/web_expired[\r\n]')) then
        if dl.resumable then
            self:_preserveWorkspace(dl,'web_expired')
        else
            self:_releaseStandby(dl);self:_cleanupWorkspace(dl)
            if dl.progress_dialog then dl.progress_dialog:close();dl.progress_dialog=nil end
            self:_notifyCompletion(dl,false,'web_expired');self:_finishJob(dl)
        end
        if not dl.reading_auth_recovery and not dl.full_auth_recovery and not dl.manual_auth_recovery then
            self.show_info(_(dl.resumable
                and 'WeRead login expired. Download paused; completed chapters are kept. Sign in again and choose Download full book to resume.'
                or 'WeRead login expired. Please sign in again and retry the download.'))
        end
        return false
    end
    if rate_limited(err) then self:_rateLimit(dl);return false end
    if type(err) == 'string' and err:match('^native_candidate/') then
        dl.native_failure = err:match('^native_candidate/([a-z_]+)')
        if dl.resumable then
            self:_preserveWorkspace(dl,dl.native_failure)
            self.show_info(_(dl.native_failure=='auth_expired'
                and 'E-Ink authorization expired. Sign in again or turn off experimental E-Ink resources.'
                or 'Experimental E-Ink resources could not be downloaded. Try again later or turn them off.'))
            return false
        end
        self:_failChapter(dl, err)
        return false
    end
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    dl.chapter_source_retries = dl.chapter_source_retries or {}
    local attempt = (dl.chapter_source_retries[uid] or 0) + 1
    dl.chapter_source_retries[uid] = attempt
    if attempt > 2 then
        dl.chapter_source_retries[uid] = nil
        self:_failChapter(dl, err)
        return false
    end
    logger.warn("chapter source download failed; retrying:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "attempt=", tostring(attempt),
        "error=", log_error(err))
    self:_setStage(dl,
        T(_("Retrying chapter %1/%2 · attempt %3"),
            tostring(dl.index), tostring(dl.total), tostring(attempt)),
        dl.index - 1)
    self:_scheduleGuarded(dl, function() self:_step(dl) end, 0.8 * attempt)
    return true
end

local function add_footnote_stats(total, current)
    for _i, key in ipairs({
        "candidates", "converted", "image_notes", "backlinks",
        "removed_note_blocks", "unresolved", "native_links",
    }) do
        total[key] = (tonumber(total[key]) or 0) + (tonumber(current and current[key]) or 0)
    end
end

function Downloader:_footnoteStep(dl)
    if dl.cancelled then
        if dl.resumable then
            self:_preserveWorkspace(dl, dl.cancel_reason or "cancelled")
        else
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
            self:_finishJob(dl)
        end
        if not dl.prefetch then
            self.show_transient(_("Download cancelled"), 2)
        end
        return
    end
    local job = dl.footnote_job
    if not job then
        dl.footnotes_done = true
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end
    if job.index > #dl.selected then
        dl.footnotes_done = true
        dl.footnote_job = nil
        if job.css_needed then
            dl.state.css = (dl.state.css or "") .. "\n"
                .. Footnotes.FOOTNOTES_CSS
        end
        logger.info("book footnotes processed:",
            "candidates=", tostring(dl.footnote_stats.candidates),
            "converted=", tostring(dl.footnote_stats.converted),
            "images=", tostring(dl.footnote_stats.image_notes),
            "backlinks=", tostring(dl.footnote_stats.backlinks),
            "removed_note_blocks=", tostring(dl.footnote_stats.removed_note_blocks),
            "unresolved=", tostring(dl.footnote_stats.unresolved),
            "fallback=", tostring(dl.footnote_stats.fallback))
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end

    local chapter = (job.chapters or dl.selected)[job.index]
    local uid = tostring(chapter.chapterUid or job.index)
    self:_setStage(dl,
        T(_("Processing footnotes · chapter %1/%2"),
            tostring(job.index), tostring(#dl.selected)), dl.total)
    local original = dl.bodies[uid]
    if dl.resumable then
        original = Content.load_full_download_chapter(
            dl.workspace, chapter, job.index)
    elseif dl.separate_chapters then
        local reason
        original, reason = Content.load_download_chapter_text(dl.workspace, job.index)
        if not original then self:_chapterStagingFailed(dl, reason); return end
    end
    local started = time.now()
    local ok, transformed, stats = pcall(Footnotes.transform_chapter,
        original, dl.footnote_scans[uid], job.index_data)
    local output = original
    if ok then
        local valid, validation_error = Footnotes.validate(transformed)
        if valid then
            output = transformed
            add_footnote_stats(dl.footnote_stats, stats)
            if Footnotes.has_converted(stats) then job.css_needed = true end
        else
            dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
            logger.warn("footnote transform validation failed; keeping original chapter:",
                "chapter_uid=", uid, "error=", log_error(validation_error))
        end
    else
        dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
        logger.warn("footnote transform failed; keeping original chapter:",
            "chapter_uid=", uid, "error=", log_error(transformed))
    end
    if dl.resumable then
        Content.save_full_download_rendered_chapter(dl.workspace, chapter, job.index, output)
    elseif dl.separate_chapters then
        if output ~= original then
            local saved, reason = Content.stage_download_chapter_text(dl.workspace, job.index, output)
            if not saved then self:_chapterStagingFailed(dl, reason); return end
        end
    else
        dl.bodies[uid] = output
    end
    self:_perf(dl, "footnotes", started, "chapter_uid=", uid,
        "ok=", tostring(ok), "fallback=", tostring(not ok))
    job.index = job.index + 1
    self:_scheduleGuarded(dl, function() self:_footnoteStep(dl) end)
end

function Downloader:_startFootnotes(dl)
    dl.footnote_scans = dl.footnote_scans or {}
    dl.footnote_stats = dl.footnote_stats or {
        candidates = 0,
        converted = 0,
        image_notes = 0,
        backlinks = 0,
        removed_note_blocks = 0,
        unresolved = 0,
        fallback = 0,
    }
    local selected = dl.resumable and dl.chapters or dl.selected
    if dl.resumable then
        -- Keep source checkpoints pristine. Footnote conversion removes
        -- consumed definitions, so its output belongs in a disposable
        -- rendering directory that can be rebuilt after an interrupted run.
        Content.reset_full_download_rendered_text(dl.workspace)
    end
    local scans = {}
    local chapter_hrefs = {}
    for chapter_index, chapter in ipairs(selected or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        if not dl.single_chapter and not dl.separate_chapters then
            chapter_hrefs[uid] = string.format('chapter-%03d.xhtml', chapter_index)
        end
        if dl.resumable then
            local body = Content.load_full_download_chapter(
                dl.workspace, chapter, chapter_index)
            local scan_ok, scan = pcall(Footnotes.scan_chapter, body, chapter)
            if scan_ok then
                dl.footnote_scans[uid] = scan
            else
                logger.warn("checkpoint footnote scan failed; keeping original chapter:",
                    "chapter_uid=", uid, "error=", log_error(scan))
            end
        end
        if dl.footnote_scans[uid] then
            scans[uid] = dl.footnote_scans[uid]
        end
    end
    dl.footnote_job = {
        index = 1,
        chapters = selected,
        index_data = Footnotes.build_book_index(scans, selected, chapter_hrefs),
        css_needed = false,
    }
    self:_scheduleGuarded(dl, function() self:_footnoteStep(dl) end)
end

function Downloader:_finishChapter(dl)
    if dl.cancelled then self:_step(dl); return end
    if not dl.current then return end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setStage(dl,
        stage_text, dl.index - 0.1)
    local started = time.now()
    local ok, result = pcall(function()
        local function finalize(client)
            if dl.current.native_assets then
                return { xhtml = dl.current.xhtml, assets = dl.current.native_assets, state = dl.state }
            end
            local xhtml, assets = Content.finalize_single_chapter_content(
                client or self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state)
            if dl.separate_chapters then
                local saved, reason = Content.stage_download_chapter_text(dl.workspace, #dl.selected + 1, xhtml)
                if not saved then return { staging_error = reason or "chapter storage unavailable" } end
                xhtml = nil
            end
            return { xhtml = xhtml, assets = assets, state = dl.state }
        end
        if cache.download_book_images then return self:_runInterruptible(dl, finalize) end
        return finalize()
    end)
    if dl.cancelled then self:_step(dl); return end
    if dl.resumable and not full_scope_current(self.settings,dl) then self:_step(dl);return end
    self:_perf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, result)
        return
    end
    if result.staging_error then self:_chapterStagingFailed(dl, result.staging_error); return end
    local xhtml, chapter_assets = result.xhtml, result.assets
    dl.state = result.state
    local uid = tostring(chapter.chapterUid or dl.index)
    if dl.resumable then
        local checkpoint_ok,checkpoint_error=pcall(function()
            return self:_runInterruptible(dl,function()
                if not full_scope_current(self.settings,dl) then error('download/session_changed',0) end
                if dl.native_chapter_resources
                    and not require('weread.lib.native_read_access').matches(self.settings,dl.native_selected) then
                    error('native_candidate/session_changed',0)
                end
                Content.save_full_download_css(dl.workspace, dl.state.css)
                local web_images
                if cache.download_book_images and not dl.current.native_assets then
                    web_images=require('weread.lib.web_image_receipt').stage(dl.workspace,chapter_assets or {})
                end
                Content.save_full_download_chapter(dl.workspace, chapter, dl.index, xhtml,
                    FileIdentity.check(dl.source_identity, dl.book), dl.current.position_receipt,
                    dl.current.native_style, dl.current.native_asset_receipt,web_images)
                if not full_scope_current(self.settings,dl) then error('download/session_changed',0) end
                return true
            end)
        end)
        if dl.cancelled then self:_step(dl);return end
        if not full_scope_current(self.settings,dl) then self:_step(dl);return end
        if dl.native_chapter_resources and not require('weread.lib.native_read_access').matches(self.settings,dl.native_selected) then
            self:_step(dl);return
        end
        if not checkpoint_ok then self:_failChapter(dl,checkpoint_error);return end
        dl.completed[dl.index] = true
        dl.completed_count = dl.completed_count + 1
    elseif not dl.separate_chapters then
        dl.bodies[uid] = xhtml
    end
    dl.assets_by_uid = dl.assets_by_uid or {}
    dl.assets_by_uid[uid] = chapter_assets or {}
    table.insert(dl.selected, chapter)
    if not dl.resumable then
        for _i, asset in ipairs(chapter_assets or {}) do
            table.insert(dl.assets, asset)
            dl.asset_bytes = (dl.asset_bytes or 0) + (tonumber(asset.size) or 0)
        end
    end
    logger.info("download assets staged:",
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_assets=", tostring(#(chapter_assets or {})),
        "total_asset_bytes=", tostring(dl.asset_bytes or 0),
        "lua_kb=", string.format("%.1f", collectgarbage("count")))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_step(dl)
    if dl.cancelled then
        if dl.resumable then
            self:_preserveWorkspace(dl, dl.cancel_reason or "cancelled")
        else
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
            self:_finishJob(dl)
        end
        if not dl.prefetch then
            self.show_transient(_("Download cancelled"), 2)
        end
        return
    end

    if dl.resumable and not full_scope_current(self.settings,dl) then
        self:_preserveWorkspace(dl,'account_changed')
        if not dl.prefetch then self.show_info(_('The account changed. The chapter download was stopped.')) end
        return
    end

    if dl.native_chapter_resources and not require('weread.lib.native_read_access').matches(self.settings, dl.native_selected) then
        if dl.resumable then self:_preserveWorkspace(dl,'account_changed')
        else
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            if dl.progress_dialog then dl.progress_dialog:close(); dl.progress_dialog = nil end
            self:_notifyCompletion(dl, false, 'account_changed')
            self:_finishJob(dl)
        end
        if not dl.prefetch then self.show_info(_('The account changed. The chapter download was stopped.')) end
        return
    end

    if dl.index > dl.total then
        if #dl.selected == 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            logger.err("book download failed: no chapters downloaded")
            self:_notifyCompletion(dl, false, "no_chapters_downloaded")
            self:_finishJob(dl)
            if not dl.prefetch then
                if dl.native_failure == 'auth_expired' then
                    self.show_info(_('E-Ink authorization expired. Sign in again or turn off experimental E-Ink resources.'))
                elseif dl.native_failure then
                    self.show_info(_('Experimental E-Ink resources could not be downloaded. Try again later or turn them off.'))
                else
                    self.show_info(_("No chapters were downloaded."))
                end
            end
            return
        end
        -- A full-book cache must be complete. Saving the chapters that happened
        -- to succeed under the stable `full.epub` path makes KOReader present a
        -- structurally valid but truncated book and replaces any previous good
        -- cache. Explicit single- or multi-chapter jobs remain best-effort.
        if dl.suffix == "full" and #dl.failed > 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            if dl.resumable then
                self:_preserveWorkspace(dl, "incomplete_full_book")
            else
                self:_releaseStandby(dl)
                self:_cleanupWorkspace(dl)
            end
            logger.warn(
                "full-book download aborted after chapter failures:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed),
                "total=", tostring(dl.total)
            )
            if not dl.resumable then
                self:_notifyCompletion(dl, false, "incomplete_full_book")
                self:_finishJob(dl)
            end
            if not dl.prefetch then
                local message = dl.resumable
                    and "Full-book download paused: %1 of %2 chapters failed.\n\nCompleted chapters were kept. Choose Download full book again to continue."
                    or "Full-book download stopped: %1 of %2 chapters failed.\n\nNo incomplete EPUB was saved. Please retry the download."
                self.show_info(T(_(message), tostring(#dl.failed), tostring(dl.total)))
            end
            return
        end
        -- The in-memory completion map is only an optimization for skipping
        -- chapters. Before packaging, read every checkpoint marker again so a
        -- partially written or externally removed chapter can never result in
        -- a truncated EPUB.
        if dl.resumable and not dl.workspace_verified then
            local completed_count = self:_restoreFullDownloadCheckpoint(dl)
            if dl.cancelled then self:_step(dl); return end
            if not full_scope_current(self.settings,dl) then self:_step(dl);return end
            if completed_count < dl.total then
                for chapter_index = 1, dl.total do
                    if not dl.completed[chapter_index] then
                        dl.index = chapter_index
                        break
                    end
                end
                dl.footnote_scans = {}
                dl.footnotes_done = false
                self:_setStage(dl,
                    T(_("Verifying downloaded chapters %1/%2"),
                        tostring(completed_count), tostring(dl.total)),
                    completed_count)
                self:_scheduleGuarded(dl, function() self:_step(dl) end)
                return
            end
            dl.workspace_verified = true
        end
        if dl.footnote_scans and not dl.footnotes_done then
            self:_startFootnotes(dl)
            return
        end
        self:_setStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local ok, package = pcall(function()
            return self:_runInterruptible(dl, function()
                local packaging_book = {}
                for key, value in pairs(dl.book) do
                    if key ~= "annotation_documents" then packaging_book[key] = value end
                end
                local function native_guard()
                    if not full_scope_current(self.settings,dl) or dl.native_chapter_resources
                        and not require('weread.lib.native_read_access').matches(self.settings, dl.native_selected) then
                        error('native_candidate/session_changed', 0)
                    end
                    return true
                end
                local function source_for(uid)
                    local receipt = dl.position_sources and dl.position_sources[uid]
                    return receipt and { workspace = dl.workspace, receipt = receipt } or nil
                end
                local path, chapter_paths
                if dl.single_chapter then
                    local chapter = dl.selected[1]
                    local uid = tostring(chapter.chapterUid or 1)
                    path = Content.save_chapter_epub(
                        self.settings, packaging_book, chapter, dl.bodies[uid],
                        (dl.assets_by_uid and dl.assets_by_uid[uid]) or dl.assets,
                        dl.state.css, dl.source_identity, source_for(uid), nil,
                        (dl.native_chapter_resources or dl.full_auth_scope) and native_guard or nil
                    )
                elseif dl.separate_chapters then
                    local paths = {}
                    for chapter_index, chapter in ipairs(dl.selected) do
                        local uid = tostring(chapter.chapterUid or chapter_index)
                        local xhtml, reason = Content.load_download_chapter_text(dl.workspace, chapter_index)
                        if not xhtml then error(reason or "chapter text is missing", 0) end
                        paths[uid] = Content.save_chapter_epub(
                            self.settings, packaging_book, chapter, xhtml,
                            (dl.assets_by_uid and dl.assets_by_uid[uid]) or {},
                            dl.state.css, dl.source_identity, source_for(uid)
                        )
                    end
                    path, chapter_paths = paths[tostring(dl.selected[1].chapterUid or 1)], paths
                else
                    local cover_data
                    local cover_url = WeRead.normalize_cover_url(dl.book.cover)
                    if cover_url and cover_url ~= "" then
                        pcall(function()
                            cover_data = self.client:get_binary(cover_url)
                        end)
                    end
                    if dl.cancelled then return end
                    if dl.resumable then
                        for chapter_index, chapter in ipairs(dl.chapters) do
                            if not Content.full_download_rendered_chapter_exists(
                                dl.workspace, chapter, chapter_index) then
                                error("missing rendered chapter " .. tostring(chapter_index))
                            end
                        end
                    end
                    path = Content.save_book_epub(
                        self.settings, packaging_book,
                        dl.resumable and dl.chapters or dl.selected,
                        dl.resumable and { __workspace_text_dir = dl.workspace.rendered_text_dir,
                            __source_workspace = dl.workspace } or dl.bodies,
                        dl.suffix,
                        dl.resumable and Content.full_download_workspace_assets(dl.workspace,dl.chapters,dl.state.css) or dl.assets,
                        dl.state.css, cover_data, dl.source_identity,
                        { workspace = dl.workspace, receipts = dl.position_sources or {} }, nil,
                        (dl.native_chapter_resources or dl.full_auth_scope) and native_guard or nil
                    )
                end
                return { path = path, chapter_paths = chapter_paths, cache_dir = packaging_book.cache_dir }
            end)
        end)
        local path = ok and package and package.path or package
        local chapter_paths = ok and package and package.chapter_paths
        if dl.cancelled then self:_step(dl); return end
        if dl.resumable and not full_scope_current(self.settings,dl) then self:_step(dl);return end
        if dl.native_chapter_resources and not require('weread.lib.native_read_access').matches(self.settings, dl.native_selected) then
            self:_step(dl); return
        end
        self:_perf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_releaseStandby(dl)
        if ok then
            local book_id = tostring(dl.book.book_id or dl.book.bookId or "")
            local change = { cached_chapters = {}, cache_dir = package.cache_dir,
                reader_url = dl.book.reader_url or WeRead.reader_url(book_id) }
            local function add_chapter(chapter, uid, filename)
                change.cached_chapters[uid] = filename
                if Content.register_annotation_document then
                    Content.register_annotation_document(change, filename, { chapter })
                end
            end
            if dl.single_chapter then
                local chapter = dl.selected[1]
                add_chapter(chapter, tostring(chapter.chapterUid or 1), path)
            elseif dl.separate_chapters then
                for index, chapter in ipairs(dl.selected) do
                    local uid = tostring(chapter.chapterUid or index)
                    add_chapter(chapter, uid, chapter_paths[uid])
                end
            else
                change.cached_full_book = path
                if Content.register_annotation_document then
                    Content.register_annotation_document(change, path, dl.resumable and dl.chapters or dl.selected)
                end
            end
            local recorded, reason = self:_recordDownload(dl, book_id, change)
            if not recorded then
                if dl.resumable then self:_preserveWorkspace(dl, reason)
                else self:_notifyCompletion(dl, false, reason);self:_finishJob(dl) end
                if not dl.prefetch then self.show_info(_("Could not save book information. Check storage and try again.")) end
                return
            end
            self:_cleanupWorkspace(dl)
        end
        if not ok then
            logger.err("save downloaded book failed:", log_error(path))
            self:_notifyCompletion(dl, false, path)
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(path)))
            end
            return
        end
        self.refresh_shelf()
        -- Add only a combined full-book EPUB to the local collection. In
        -- separate-chapter mode `path` is an individual chapter EPUB.
        if not dl.single_chapter and not dl.separate_chapters then
            pcall(function()
                local ReadCollection = require("readcollection")
                local COLLECTION_NAME = self.settings.collection_name or "weread"
                if not ReadCollection.coll then
                    ReadCollection:_read()
                end
                if not ReadCollection.coll[COLLECTION_NAME] then
                    ReadCollection:addCollection(COLLECTION_NAME)
                end
                if not ReadCollection:isFileInCollection(path, COLLECTION_NAME) then
                    ReadCollection:addItem(path, COLLECTION_NAME)
                    ReadCollection:write({ [COLLECTION_NAME] = true })
                end
            end)
        end
        if #dl.failed > 0 then
            logger.warn(
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info("book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end
        if dl.footnote_stats and dl.footnote_stats.unresolved > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 footnote reference(s) could not be resolved and were kept as original links."),
                tostring(dl.footnote_stats.unresolved)
            )
        end
        if dl.footnote_stats and dl.footnote_stats.fallback > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 chapter(s) kept their original footnote markup after validation fallback."),
                tostring(dl.footnote_stats.fallback)
            )
        end
        self:_perf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches),
            "footnotes_converted=", tostring(dl.footnote_stats and dl.footnote_stats.converted or 0),
            "footnotes_unresolved=", tostring(dl.footnote_stats and dl.footnote_stats.unresolved or 0))
        self:_notifyCompletion(dl, true, path)
        self:_finishJob(dl)
        if dl.open_on_complete then
            if chapter_open_current(dl.read_current) then self.open_file(path,dl.book) end
            return
        end
        if dl.silent_completion or not chapter_open_current(dl.read_current) then
            return
        end
        if not dl.offer_read then
            self.show_transient(
                T(_("Downloaded %1 chapters."), tostring(#dl.selected)), 2)
            return
        end
        local read_now=self.safe_callback(_("Read now"),function() self.open_file(path,dl.book) end)
        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = function() if chapter_open_current(dl.read_current) then read_now() end end,
            cancel_text = _("Close"),
        })
        return
    end

    if dl.resumable and self:_skipCompletedChapterBatch(dl) then return end

    local chapter = dl.chapters[dl.index]
    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)
    local started = time.now()
    local ok, result = pcall(function()
        return self:_runInterruptible(dl, function(client)
            local xhtml, source = Content.fetch_single_chapter_source(
                client, self.settings, dl.book, chapter, dl.state)
            local candidate
            local native_style,native_asset_receipt
            if dl.native_chapter_resources then
                candidate = require('weread.lib.native_chapter_candidate').fetch(
                    client, self.settings, dl.book, chapter, xhtml, source, dl.workspace,
                    dl.native_selected and dl.native_selected.fingerprint,nil,
                    dl.resumable and function(name)
                        local version=FileIdentity.check(dl.source_identity,dl.book)
                        if dl.source_identity and dl.source_identity.changed then return false end
                        return Content.full_download_asset_repairable(dl.workspace,chapter,dl.index,name,
                            version)
                    end or nil)
                if candidate then
                    xhtml=candidate.xhtml
                    dl.state.used_asset_names=dl.state.used_asset_names or {}
                    for _,asset in ipairs(candidate.assets) do
                        local name=asset.href:match('^images/([^/]+)$')
                        if not name then error('native_candidate/invalid_asset',0) end
                        dl.state.used_asset_names[name]=true
                    end
                    if dl.resumable then
                        local staged,value=pcall(function()
                            return {style=Content.stage_full_download_style(dl.workspace,
                                candidate.css..'\n'..Footnotes.FOOTNOTES_CSS,function(digest)
                                    local version=FileIdentity.check(dl.source_identity,dl.book)
                                    if dl.source_identity and dl.source_identity.changed then return false end
                                    return Content.full_download_style_repairable(dl.workspace,chapter,dl.index,digest,
                                        version)
                                end),
                                assets=Content.stage_full_download_assets(dl.workspace,candidate.assets)}
                        end)
                        if not staged then error('native_candidate/storage',0) end
                        native_style,native_asset_receipt=value.style,value.assets
                    else dl.state.css=candidate.css end
                end
            end
            local receipt = source and Content.store_position_source(dl.workspace, dl.book, chapter, source)
            FileIdentity.check(dl.source_identity, dl.book)
            return { xhtml = xhtml, position_receipt = receipt, state = dl.state, book = reader_book(dl.book),
                native_assets = candidate and candidate.assets,
                native_style = native_style,
                native_asset_receipt = native_asset_receipt,
                source_changed = dl.source_identity and dl.source_identity.changed }
        end)
    end)
    if dl.cancelled then self:_step(dl); return end
    if dl.resumable and not full_scope_current(self.settings,dl) then self:_step(dl);return end
    if dl.native_chapter_resources and not require('weread.lib.native_read_access').matches(self.settings, dl.native_selected) then
        self:_step(dl); return
    end
    self:_perf(dl, "chapter_source", started, "ok=", tostring(ok))
    if not ok then
        self:_retryChapterSource(dl, result)
        return
    end
    local xhtml = result.xhtml
    dl.state = result.state
    apply_reader_book(dl.book, result.book)
    if dl.source_identity and result.source_changed then dl.source_identity.changed = true end
    FileIdentity.check(dl.source_identity, dl.book)
    if dl.chapter_source_retries then
        dl.chapter_source_retries[tostring(chapter.chapterUid or dl.index)] = nil
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    if not dl.resumable then
        dl.position_sources = dl.position_sources or {}
        dl.position_sources[uid] = result.position_receipt
    end
    local scan_ok, scan = pcall(Footnotes.scan_chapter, xhtml, chapter)
    dl.footnote_scans = dl.footnote_scans or {}
    if scan_ok then
        dl.footnote_scans[uid] = scan
    else
        logger.warn("footnote scan failed; chapter will keep original footnote markup:",
            "chapter_uid=", uid, "error=", log_error(scan))
    end
    dl.current = { chapter = chapter, xhtml = xhtml, position_receipt = result.position_receipt,
        native_assets = result.native_assets, native_style = result.native_style,
        native_asset_receipt = result.native_asset_receipt }
    self:_finishChapter(dl)
end

return Downloader
