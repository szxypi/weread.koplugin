-- KOReader event lifecycle and reader-state orchestration.
local Content = require("weread.lib.content")
local FileIdentity = require("weread.lib.book_file_identity")
local logger = require("weread.lib.logger").scoped("Prefetch")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local WeRead = require("weread.lib.protocol")
local _ = PluginUtil.tr
local T = PluginUtil.T
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists
local log_error = PluginUtil.log_error

local M = {}
local function selection_action(host,action)
    local module=package.loaded['weread.ui.selection_thought']
    if module then module[action](host) end
end
local function personal_action(host,action)
    local module=package.loaded['weread.ui.personal_marks']
    if action=='attach' then module=require('weread.ui.personal_marks') end
    if module then module[action](host) end
end

-- KOReader v2026.03 assumes ReaderHighlight's visible box cache has already
-- been populated when a tap arrives. During a fast document switch there is a
-- short window after ReaderReady where the cache is still nil, and the native
-- handler crashes while taking its length. Keep the compatibility guard local
-- to the reader instance and leave KOReader's normal handler unchanged once
-- the cache has been initialized.
function M:_installReaderHighlightTapGuard()
    local highlight = self.ui and self.ui.highlight
    if not highlight or type(highlight.onTap) ~= "function" then
        return false
    end
    if self._reader_highlight_guard_target == highlight then
        return true
    end
    self:_removeReaderHighlightTapGuard()

    local original = highlight.onTap
    self._reader_highlight_guard_target = highlight
    self._reader_highlight_original_on_tap = original
    highlight.onTap = function(highlight_self, arg, ges)
        local view_highlight = highlight_self.view and highlight_self.view.highlight
        if ges and view_highlight and type(view_highlight.visible_boxes) ~= "table" then
            view_highlight.visible_boxes = {}
        end
        return original(highlight_self, arg, ges)
    end
    return true
end

function M:_removeReaderHighlightTapGuard()
    local highlight = self._reader_highlight_guard_target
    local original = self._reader_highlight_original_on_tap
    if highlight and original and highlight.onTap ~= original then
        highlight.onTap = original
    end
    self._reader_highlight_guard_target = nil
    self._reader_highlight_original_on_tap = nil
end

function M:onShowWeRead()
    self:showAccountStatus()
end

function M:onWeReadSyncProgress()
    local book_id = self:detectWeReadBook()
    if not book_id or WeRead.is_mp_book(book_id) then
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
        return false
    end
    if not self:requireLogin(true, false) then
        return false
    end
    if require('weread.ui.native_position_review').open(self) then return true end
    self.progress_sync:sync_now()
    return true
end

function M:handleEndOfBook(status_self)
    local action = G_reader_settings and G_reader_settings:readSetting("end_document_action") or "pop-up"
    local book_id = self:detectWeReadBook()
    if not book_id then
        return self._orig_onEndOfBook(status_self)
    end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    self:ensureChaptersLoaded(book)
    local file = self.ui.document and self.ui.document.file
    local current_idx, current_ch, is_full_book = self:getChapterInfoFromFile(book, file)
    local next_ch = (not is_full_book) and current_idx and book.chapters[current_idx + 1]

    if action == "next_file" then
        if next_ch then
            self:openChapter(book, next_ch)
        else
            self:showInfo(_("You have reached the last chapter."))
        end
        return true
    end

    -- For every other end-of-document action, prefer our WeRead navigation
    -- dialog. This intentionally overrides the global end_document_action
    -- (pop-up, book_status, …) for WeRead books; fall back to the native
    -- handler only when the dialog cannot be built.
    if self:showEndOfBookDialog(book_id) then
        return true
    end

    return self._orig_onEndOfBook(status_self)
end

function M:onReaderReady()
    local review=package.loaded['weread.ui.native_position_review'];if review then review.cancel(self) end
    require('weread.ui.chapter_links').detach(self)
    require('weread.lib.rich_footnotes').detach(self)
    if self.closeOfflineTimeUI then self:closeOfflineTimeUI() end
    personal_action(self,'detach')
    if self.cancelShelfCovers then self:cancelShelfCovers() end
    if self.cancelShelfProgress then self:cancelShelfProgress() end
    if self.cancelMPDownloadRecovery then self:cancelMPDownloadRecovery() end
    if self.cancelMPArticleCleanup then self:cancelMPArticleCleanup() end
    if self.cancelMPArticleActions then self:cancelMPArticleActions() end
    if self.cancelWebRenewal then self:cancelWebRenewal() end
    if self.cancelMPArticleCatalog then self:cancelMPArticleCatalog() end
    if self.cancelMPArticleDownload then self:cancelMPArticleDownload() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
    if self.cancelLocalNotesExport then self:cancelLocalNotesExport() end
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    local perf = PluginUtil.reader_open_perf
    local opened = perf("reader_ready_begin", nil, "session=", self._reader_session_gen)
    self:_teardownThoughtInterception()
    self:_installReaderHighlightTapGuard()

    local weread_book_id = self:detectWeReadBook()
    -- Cache it so the per-tap handler (_onThoughtTap) does not have to re-scan
    -- the whole book table on every screen tap.
    self._current_weread_book_id = weread_book_id
    if weread_book_id then require('weread.lib.rich_footnotes').attach(self) end
    selection_action(self,'detach')
    if weread_book_id and self.ui and self.ui.highlight and type(self.ui.highlight.addToHighlightDialog)=='function' then
        require('weread.ui.selection_thought').attach(self)
    end
    if weread_book_id then FileIdentity.read_document(self.ui.document, weread_book_id) end
    if weread_book_id and self.recordRecentReading then self:recordRecentReading(weread_book_id) end
    if weread_book_id then
        -- Always register the tap interception: even when annotations are hidden
        -- we must intercept taps on thought links to suppress the native footnote
        -- popup. Visibility is decided inside _onThoughtTap / applyAnnotationVisibility.
        self:_setupThoughtInterception()
        if self.settings:get("cache").show_annotations ~= false
            and not (self._usesUnifiedAnnotations and self:_usesUnifiedAnnotations()) then
            local db_session_gen = self._reader_session_gen
            UIManager:scheduleIn(0.1, function()
                if db_session_gen ~= self._reader_session_gen
                    or self._current_weread_book_id ~= weread_book_id then
                    return
                end
                self:_ensureThoughtDB(weread_book_id)
            end)
        end
        if not self._orig_onEndOfBook and self.ui.status and type(self.ui.status.onEndOfBook) == "function" then
            self._orig_onEndOfBook = self.ui.status.onEndOfBook
            self.ui.status.onEndOfBook = function(status_self)
                return self:handleEndOfBook(status_self)
            end
        end
    else
        if self._orig_onEndOfBook and self.ui.status then
            self.ui.status.onEndOfBook = self._orig_onEndOfBook
            self._orig_onEndOfBook = nil
        end
    end

    -- Register the EPUB-safe external annotation prototype for any CREngine
    -- document. The view module remains empty until the user adds a prototype
    -- range, so unsupported/non-participating books pay only an empty module
    -- function call during paint.
    local prepared = perf("reader_setup", opened, "book_id=", weread_book_id or "local")
    self:_setupXPointerOverlayPrototype()
    perf("overlay_setup", prepared)
    if self.onUnifiedAnnotationsReady then self:onUnifiedAnnotationsReady() end
    personal_action(self,'attach')

    local annotations_ready = perf("annotations_ready", opened)
    if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
    if self.source_navigation then self.source_navigation:cancel() end
    if self.source_close then self.source_close:on_reader_ready(weread_book_id) end
    if self.source_position then self.source_position:on_reader_ready() end
    self.progress_sync:on_reader_ready()
    if weread_book_id then require('weread.ui.chapter_links').attach(self) end
    if self.onTranslationReaderReady then self:onTranslationReaderReady() end
    local prefetch_session_gen = self._reader_session_gen
    UIManager:scheduleIn(0.2, function()
        if prefetch_session_gen ~= self._reader_session_gen then return end
        self:maybePrefetchNextChapter(weread_book_id)
    end)
    local _started, _title, reason = self.read_report:on_reader_ready()
    if self.offline_time then self.offline_time:resume() end
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "auto" and reason == "document_not_weread" then
        self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
    end
    perf("reader_services", annotations_ready)
    perf("reader_ready_total", opened)
end

function M:onPageUpdate()
    local review=package.loaded['weread.ui.native_position_review'];if review then review.view_changed(self) end
    require('weread.ui.chapter_links').view_changed(self)
    personal_action(self,'update')
    selection_action(self,'view_changed')
    if self._read_resume_token then require('weread.ui.read_resume').view_changed(self) end
    if self.onCloudSourceViewChanged then self:onCloudSourceViewChanged() end
    if self.source_navigation then self.source_navigation:on_view_changed() end
    if self.source_upload then self.source_upload:on_view_changed() end
    if self.source_position then self.source_position:on_view_changed() end
    self.progress_sync:on_page_update()
    if self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
end

function M:onPosUpdate()
    local review=package.loaded['weread.ui.native_position_review'];if review then review.view_changed(self) end
    require('weread.ui.chapter_links').view_changed(self)
    personal_action(self,'update')
    selection_action(self,'view_changed')
    if self._read_resume_token then require('weread.ui.read_resume').view_changed(self) end
    if self.onCloudSourceViewChanged then self:onCloudSourceViewChanged() end
    if self.source_navigation then self.source_navigation:on_view_changed() end
    if self.source_upload then self.source_upload:on_view_changed() end
    if self.source_position then self.source_position:on_view_changed() end
    self.progress_sync:on_page_update()
    if self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
end

function M:onCloseDocument()
    local review=package.loaded['weread.ui.native_position_review'];if review then review.cancel(self) end
    require('weread.ui.chapter_links').detach(self)
    require('weread.lib.rich_footnotes').detach(self)
    if self.closeOfflineTimeUI then self:closeOfflineTimeUI() end
    personal_action(self,'detach')
    selection_action(self,'detach')
    require('weread.ui.mp_reader_open').cancel(self)
    if self._read_resume_token then require('weread.ui.read_resume').on_close(self) end
    if self.cancelShelfCovers then self:cancelShelfCovers() end
    if self.cancelShelfProgress then self:cancelShelfProgress() end
    if self.cancelMPDownloadRecovery then self:cancelMPDownloadRecovery() end
    if self.cancelMPArticleCleanup then self:cancelMPArticleCleanup() end
    if self.cancelMPArticleActions then self:cancelMPArticleActions() end
    if self.cancelWebRenewal then self:cancelWebRenewal() end
    if self.cancelMPArticleCatalog then self:cancelMPArticleCatalog() end
    if self.cancelMPArticleDownload then self:cancelMPArticleDownload() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelShelfState then self:cancelShelfState() end
    if self.closeReadingLanguageDocument then self:closeReadingLanguageDocument() end
    if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
    if self.cancelLocalNotesExport then self:cancelLocalNotesExport() end
    if self.closeReaderLinkUI then self:closeReaderLinkUI() end
    if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
    if self.cancelProfileRefresh then self:cancelProfileRefresh() end
    if self.cancelReadStatsRequest then self:cancelReadStatsRequest() end
    if self.cancelBookMetadata then self:cancelBookMetadata() end
    if self.cancelBookReading then self:cancelBookReading() end
    if self.cancelDiscoveryRequest then self:cancelDiscoveryRequest() end
    if self.source_navigation then self.source_navigation:cancel() end
    local source_position = self.source_position and self.source_position:current()
    local close_token,close_position = self.progress_sync:prepare_close(source_position)
    if self.source_position then self.source_position:stop() end
    if self.native_renewal then self.native_renewal:cancel() end
    if self.cancelShelfRefresh then self:cancelShelfRefresh() end
    if self.native_authorization then self.native_authorization:cancel() end
    if self.offline_time then self.offline_time:stop("no_book") end
    FileIdentity.forget(self.ui and self.ui.document)
    -- Capture the immutable local position while the document is still alive.
    -- The network upload is scheduled; stopping ReadReport below also frees any
    -- in-flight report slot before that scheduled upload begins.
    self.progress_sync:on_close_document(source_position,close_token,close_position)
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self.downloader:cancelPrefetch("document_closed")
    if self._cancelUnifiedAnnotationSync then self:_cancelUnifiedAnnotationSync() end
    self._annotation_pending_prefetch = nil
    self._annotation_context = nil
    self._current_weread_book_id = nil
    self:_teardownThoughtInterception()
    self:_teardownXPointerOverlayPrototype()
    self:_removeReaderHighlightTapGuard()

    if self._orig_onEndOfBook and self.ui.status then
        self.ui.status.onEndOfBook = self._orig_onEndOfBook
        self._orig_onEndOfBook = nil
    end

    self.read_report:on_close_document()
end

function M:onShowingReader()
    if self.cancelBookReading then self:cancelBookReading() end
    require('weread.ui.mp_file_open').cancel(self)
    require('weread.ui.mp_reader_open').cancel(self)
end

function M:onCloseWidget()
    if self.cancelBookReading then self:cancelBookReading() end
    require('weread.ui.mp_file_open').detach(self)
    require('weread.ui.mp_reader_open').detach(self)
    require('weread.ui.mp_metadata_preview').detach(self)
end

function M:showPrefetchNotice(text, timeout)
    if self.settings:get("cache").show_prefetch_notifications == false then
        return
    end
    self:showTransientInfo(text, timeout or 1)
end

function M:maybePrefetchNextChapter(book_id)
    local cache = self.settings:get("cache")
    if cache.auto_prefetch_next_chapter ~= true or not book_id then
        self.downloader:cancelPrefetch("prefetch_not_applicable")
        return false
    end

    local books = self.settings:get("books", {})
    local book = books[tostring(book_id)] or books[book_id]
    local chapters = self:ensureChaptersLoaded(book)
    local file = self.ui.document and self.ui.document.file
    if not book or not chapters or not file then
        self.downloader:cancelPrefetch("prefetch_context_missing")
        return false
    end
    local chapter_info = { self:getChapterInfoFromFile(book, file) }
    local current_index, is_full_book = chapter_info[1], chapter_info[3]
    local next_chapter = not is_full_book and current_index
        and chapters[current_index + 1] or nil
    if not next_chapter then
        self.downloader:cancelPrefetch("no_next_chapter")
        return false
    end

    local next_uid = tostring(next_chapter.chapterUid or next_chapter.chapterId or "")
    local cached = book.cached_chapters and book.cached_chapters[next_uid]
    if file_exists(cached) then
        if self.prefetchChapterAnnotations then self:prefetchChapterAnnotations(book, next_chapter) end
        if not self.downloader:isPrefetching(book, next_chapter) then
            self.downloader:cancelPrefetch("next_chapter_cached")
        end
        return true
    end
    if self.downloader:isPrefetching(book, next_chapter) then
        return true
    end

    local title = next_chapter.title or T(_("Chapter %1"), next_uid)
    return self.downloader:start(book, { next_chapter }, "chapter", {
        single_chapter = true,
        include_annotations = false,
        prefetch = true,
        start_delay = cache.show_prefetch_notifications == false and 0.1 or 0.7,
        silent_completion = true,
        offer_read = false,
        on_start = function()
            logger.info("started:",
                "book_id=", tostring(book_id),
                "chapter_uid=", next_uid,
                "title=", title)
            self:showPrefetchNotice(
                T(_("Prefetching next chapter: %1"), title), 0.5)
        end,
        on_complete = function(ok, value)
            if ok then
                -- A promoted prefetch opens the new file immediately. Its
                -- ReaderReady path can download source data for that file
                -- when both prefetch switches are enabled, so
                -- do not fork an annotation worker only to cancel it during
                -- the document switch.
                if self.prefetchChapterAnnotations
                    and not self.downloader:isPromotedPrefetch(book, next_chapter) then
                    self:prefetchChapterAnnotations(book, next_chapter)
                end
                logger.info("succeeded:",
                    "book_id=", tostring(book_id),
                    "chapter_uid=", next_uid,
                    "title=", title)
                self:showPrefetchNotice(T(_("Next chapter prefetched: %1"), title))
                return
            end
            local retry_requested = self.downloader:isPromotedPrefetch(
                book, next_chapter)
            if value == "cancelled" or value == "document_closed"
                or value == "replaced" or value == "manual_download"
                or value == "setting_disabled" or value == "prefetch_not_applicable"
                or value == "prefetch_context_missing" or value == "no_next_chapter"
                or value == "next_chapter_cached" then
                logger.info("ended without completion:",
                    "book_id=", tostring(book_id),
                    "chapter_uid=", next_uid,
                    "title=", title,
                    "reason=", tostring(value))
                return
            end
            local reason = value == "offline" and _("Network is not connected")
                or value == "low_memory" and _("Not enough free memory; prefetch skipped")
                or value == "worker_unavailable" and _("Background prefetch is unavailable")
                or value == "worker_timeout" and _("Background prefetch timed out")
                or display_error(value)
            logger.warn("failed:",
                "book_id=", tostring(book_id),
                "chapter_uid=", next_uid,
                "title=", title,
                "reason=", log_error(value))
            self:showPrefetchNotice(T(_("Next chapter prefetch failed: %1"), reason))
            if retry_requested then
                local source_file = file
                local retry_cache = self.settings:get("cache")
                local retry_delay = retry_cache.show_prefetch_notifications == false
                    and 0.1 or 1.1
                UIManager:scheduleIn(retry_delay, function()
                    if self.ui.document and self.ui.document.file == source_file then
                        self:downloadChapterAndRead(book, next_chapter)
                    end
                end)
            end
        end,
    })
end

function M:maybeStartReadReport()
    return self.read_report:maybe_start("menu")
end

function M:stopReadReport(reason)
    self.read_report:stop(reason or "explicit_stop")
end

function M:onSuspend()
    local review=package.loaded['weread.ui.native_position_review'];if review then review.cancel(self) end
    require('weread.ui.chapter_links').cancel(self)
    if self.closeOfflineTimeUI then self:closeOfflineTimeUI() end
    personal_action(self,'suspend')
    selection_action(self,'cancel')
    require('weread.ui.mp_reader_open').cancel(self)
    if self._read_resume_token then require('weread.ui.read_resume').cancel(self) end
    if self.cancelShelfCovers then self:cancelShelfCovers(true) end
    if self.cancelShelfProgress then self:cancelShelfProgress() end
    if self.cancelMPDownloadRecovery then self:cancelMPDownloadRecovery() end
    if self.cancelMPArticleCleanup then self:cancelMPArticleCleanup() end
    if self.cancelMPArticleActions then self:cancelMPArticleActions() end
    if self.cancelWebRenewal then self:cancelWebRenewal() end
    if self.cancelMPArticleCatalog then self:cancelMPArticleCatalog() end
    if self.cancelMPArticleDownload then self:cancelMPArticleDownload() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelShelfState then self:cancelShelfState() end
    if self.cancelReadingLanguage then self:cancelReadingLanguage() end
    if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
    if self.cancelLocalNotesExport then self:cancelLocalNotesExport() end
    if self.closeReaderLinkUI then self:closeReaderLinkUI() end
    if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
    if self.cancelProfileRefresh then self:cancelProfileRefresh() end
    if self.cancelReadStatsRequest then self:cancelReadStatsRequest() end
    if self.cancelBookMetadata then self:cancelBookMetadata() end
    if self.cancelBookReading then self:cancelBookReading() end
    if self.cancelDiscoveryRequest then self:cancelDiscoveryRequest() end
    if self.source_navigation then self.source_navigation:cancel() end
    local source_position = self.source_position and self.source_position:current()
    if self.source_close then self.source_close:cancel() end
    if self.source_position then self.source_position:pause("suspend") end
    if self.native_renewal then self.native_renewal:cancel() end
    if self.cancelShelfRefresh then self:cancelShelfRefresh() end
    if self.native_authorization then self.native_authorization:cancel() end
    if self.offline_time then self.offline_time:suspend() end
    if self.stopHomeStatusTimer then self:stopHomeStatusTimer() end
    if self._cancelUnifiedAnnotationSync then self:_cancelUnifiedAnnotationSync() end
    self._annotation_pending_prefetch = nil
    self.progress_sync:on_suspend(source_position)
    self.read_report:on_suspend()
end

function M:onResume()
    personal_action(self,'wake')
    if self.resumeShelfCovers then self:resumeShelfCovers() end
    self.progress_sync:on_resume()
    if self.source_position then self.source_position:resume("suspend") end
    self.read_report:on_resume()
    if self.offline_time then self.offline_time:resume() end
    if self.startHomeStatusTimer and self.shelf_view and self.shelf_view.home_layout then
        self:startHomeStatusTimer(self.shelf_view)
    end
end

function M:onReadingPaused()
    if self.offline_time then self.offline_time:pause() end
end

function M:onReadingResumed()
    if self.offline_time then self.offline_time:resume() end
end

function M:onNetworkConnected()
    if self.progress_sync then self.progress_sync:on_network_connected() end
    if self.offline_time then self.offline_time:update("network_connected", true) end
end

function M:onNetworkDisconnected()
    local review=package.loaded['weread.ui.native_position_review'];if review then review.cancel(self) end
    if self.progress_sync then self.progress_sync:on_network_disconnected() end
    if self.offline_time then self.offline_time:update("network_disconnected", false) end
end

function M:detectWeReadBook()
    if not self.ui.document then
        return nil
    end
    local file = self.ui.document.file
    if not file then
        return nil
    end
    if require("weread.lib.notes_export").is_export_path(self.settings,file) then return nil end
    if require("weread.lib.mp_export").is_export_path(self.settings,file) then return nil end
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if type(book) == "table" then
            local dir = Content.book_resolved_dir(
                self.settings, book_id, book):gsub("/+$", "") .. "/"
            if file == book.cached_file or file:sub(1, #dir) == dir then
                return book_id
            end
        end
    end

    -- Require a path boundary after the cache directory.
    local prefix = self.settings.cache_dir:gsub("/+$", "") .. "/"
    if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        return rest:match("^([^/]+)")
    end
    return nil
end

function M:ensureChaptersLoaded(book)
    if not book then return nil end
    if type(book.chapters) == "table" and #book.chapters > 0 then
        local book_id = book.book_id or book.bookId
        if self.library_db and book_id then
            self.library_db:putChapters(book_id, book.chapters)
        end
        local catalog_path = Content.catalog_cache_path(self.settings, book)
        if catalog_path and not file_exists(catalog_path) then
            local cache_ok, cache_err = Content.save_catalog_cache(
                self.client, self.settings, book, book.chapters)
            if not cache_ok then
                logger.warn("save chapter catalog cache failed:",
                    log_error(cache_err))
            end
        end
        return book.chapters
    end

    local book_id = book.book_id or book.bookId
    local chapters = Content.load_catalog_cache(
        self.client, self.settings, book)
    if type(chapters) == "table" and #chapters > 0 then
        if self.library_db then
            self.library_db:putChapters(book_id, chapters)
        end
        return chapters
    end

    chapters = self.library_db and self.library_db:getChapters(book_id) or nil
    if type(chapters) == "table" and #chapters > 0 then
        book.chapters = chapters
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            logger.warn("save chapter catalog cache failed:",
                log_error(cache_err))
        end
        return chapters
    end
    return nil
end

-- cached_file historically pointed at either a full-book EPUB or the most
-- recently downloaded single chapter. Treat it as a legacy full-book path only
-- when it does not map to exactly one chapter; new downloads use the explicit
-- cached_full_book field.
function M:getFullBookCachePath(book)
    if type(book) ~= "table" then return nil end
    if type(book.cached_full_book) == "string"
        and book.cached_full_book ~= "" and file_exists(book.cached_full_book) then
        return book.cached_full_book
    end
    local legacy = book.cached_file
    if type(legacy) ~= "string" or legacy == "" then return nil end
    local mapped_count = 0
    for _uid, path in pairs(book.cached_chapters or {}) do
        if path == legacy then mapped_count = mapped_count + 1 end
    end
    if mapped_count == 1 then return nil end
    return legacy
end

-- Retrieves chapter information for the given file path.
--
-- Parameters:
--   book: The book object from settings containing chapters and cached_chapters.
--   file_path: The absolute path of the currently open document.
--
-- Returns:
--   current_idx (number or nil): The index of the current chapter within book.chapters, if it's a single chapter file.
--   current_ch (table or nil): The chapter object of the current chapter, if it's a single chapter file.
--   is_full_book (boolean): True if the file maps to multiple chapters (e.g. a combined EPUB), false otherwise.
function M:getChapterInfoFromFile(book, file_path)
    if not book or not file_path or not book.chapters then
        return nil, nil, false
    end

    local mapped_count = 0
    local current_uid = nil
    for uid, path in pairs(book.cached_chapters or {}) do
        if path == file_path then
            mapped_count = mapped_count + 1
            current_uid = uid
        end
    end

    local full_book_path = self:getFullBookCachePath(book)
    if full_book_path == file_path then
        return nil, nil, true
    end

    local is_full_book = (mapped_count > 1)

    if mapped_count == 1 and current_uid then
        for i, ch in ipairs(book.chapters) do
            if tostring(ch.chapterUid) == tostring(current_uid) then
                return i, ch, is_full_book
            end
        end
    end

    return nil, nil, is_full_book
end

function M:onFlushSettings()
    if self.progress_sync then self.progress_sync:checkpoint_local("settings_flush") end
    if self.settings then
        self.settings:flush()
    end
end

return M
