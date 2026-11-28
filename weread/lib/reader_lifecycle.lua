-- KOReader event lifecycle and reader-state orchestration.
local Content = require("weread.lib.content")
local FileIdentity = require("weread.lib.book_file_identity")
local logger = require("weread.lib.logger").scoped("Prefetch")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local ReadAccess = require("weread.lib.read_access")
local WeRead = require("weread.lib.protocol")
local _ = PluginUtil.tr
local T = PluginUtil.T
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists
local log_error = PluginUtil.log_error

local M = {}
local function book_identity_message()
    return _('Saved book information does not match. The chapter was not linked; refresh the book and check its cache.')
end
local function selection_action(host,action)
    local module=package.loaded['weread.ui.selection_thought']
    if module then module[action](host) end
end
local function excerpt_action(host,action)
    local module=package.loaded['weread.ui.excerpt_selection']
    if action=='attach' then module=require('weread.ui.excerpt_selection') end
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
    local file=self.ui and self.ui.document and self.ui.document.file
    if require('weread.lib.native_direct_path').contains(self.settings,file) then
        return require('weread.ui.native_direct_navigation').start(self,action=='next_file' and 1 or nil)
    end
    local book_id = self:detectWeReadBook()
    if not book_id then
        return self._orig_onEndOfBook(status_self)
    end

    if action == "next_file" then
        local book = ReadAccess.load_cached_book(self.settings, book_id)
        local chapters = self:ensureChaptersLoaded(book,true)
        if not chapters then
            -- Chapter IDs identify files but cannot establish which chapter follows.
            if self:showEndOfBookDialog(book_id,true,{}) then return true end
            return self._orig_onEndOfBook(status_self)
        end
        book.chapters=chapters
        local current_idx, _, is_full_book, partial, proof = self:getChapterInfoFromFile(book, file)
        if is_full_book and partial then
            current_idx=require('weread.lib.reader_progress_chapter').combined_end(book,self.ui.document,proof)
            if not current_idx and self:showEndOfBookDialog(book_id,true) then return true end
        end
        local next_ch = current_idx and chapters[current_idx + 1]
        if next_ch then
            self:openReaderChapter(book, next_ch)
        else
            self:showInfo(_("You have reached the last chapter."))
        end
        return true
    end

    -- For every other end-of-document action, prefer our WeRead navigation
    -- dialog. This intentionally overrides the global end_document_action
    -- (pop-up, book_status, …) for WeRead books; fall back to the native
    -- handler only when the dialog cannot be built.
    if self:showEndOfBookDialog(book_id,true) then
        return true
    end

    return self._orig_onEndOfBook(status_self)
end

function M:onDocSettingsLoad(config,document)
    require('weread.lib.native_account_location').load(self,config,document)
end

function M:onSaveSettings()
    require('weread.lib.native_account_location').save(self)
end

function M:onReaderReady()
    local native_cleanup=package.loaded['weread.ui.native_direct_cleanup'];if native_cleanup then native_cleanup.cancel(self) end
    local copy_resume=package.loaded['weread.ui.native_direct_copy_resume'];if copy_resume then copy_resume.cancel(self) end
    local image_refresh=package.loaded['weread.ui.native_direct_image_refresh'];if image_refresh then image_refresh.cancel(self) end
    self._native_auto_time_epoch=(self._native_auto_time_epoch or 0)+1
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.cancel(self) end
    local time_source=package.loaded['weread.lib.native_direct_offline_time'];if time_source then time_source.cancel(self) end
    local home_resume=package.loaded['weread.ui.native_home_resume'];if home_resume then home_resume.cancel(self) end
    local direct_note=package.loaded['weread.ui.my_mark_navigation'];if direct_note and direct_note.cancel_incoming then direct_note.cancel_incoming(self) end
    local direct_close=package.loaded['weread.lib.native_direct_close'];if direct_close then direct_close.cancel(self) end
    local direct_interval=package.loaded['weread.lib.native_direct_interval']
    if direct_interval then direct_interval.cancel(self) end
    local direct_navigation=package.loaded['weread.ui.native_direct_navigation']
    if direct_navigation then direct_navigation.cancel(self) end
    local direct_position=package.loaded['weread.ui.native_direct_position']
    if direct_position then direct_position.cancel(self) end
    local direct_cloud=package.loaded['weread.ui.native_direct_cloud_open']
    if direct_cloud then direct_cloud.cancel(self) end
    local direct_search_open=package.loaded['weread.ui.native_direct_search_open']
    if direct_search_open then direct_search_open.cancel(self) end
    local direct_online_search=package.loaded['weread.ui.native_direct_online_navigation']
    if direct_online_search then direct_online_search.cancel(self) end
    require('weread.ui.prefetch_auth_recovery').cancel(self)
    self._prefetch_auth_attempts=nil
    local local_file=self.ui and self.ui.document and self.ui.document.file
    if self._personal_original_local_only~=local_file then
        self._personal_original_local_only=require('weread.lib.personal_original').take(local_file) and local_file or nil
    end
    if self.client and self.native_renewal then self.client._native_renewal=self.native_renewal end
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
    if self.cancelMPLink then self:cancelMPLink() end
    if self.cancelPersonalUpload then self:cancelPersonalUpload() end
    if self.cancelPersonalOriginal then self:cancelPersonalOriginal() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
    if self.cancelBookSearch then self:cancelBookSearch() end
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
    excerpt_action(self,'detach')
    if (weread_book_id or require('weread.lib.native_direct_path').contains(self.settings,local_file))
        and self.ui and self.ui.highlight and type(self.ui.highlight.addToHighlightDialog)=='function' then
        require('weread.ui.selection_thought').attach(self)
        if weread_book_id then excerpt_action(self,'attach') end
    end
    if weread_book_id then
        FileIdentity.read_document(self.ui.document, weread_book_id)
        require('weread.lib.native_account_location').ready(self,weread_book_id)
    end
    if weread_book_id and self.recordRecentReading then self:recordRecentReading(weread_book_id) end
    if not weread_book_id and require('weread.lib.native_direct_path').contains(self.settings,local_file) then
        require('weread.ui.native_direct_reconnect').ready(self)
        require('weread.ui.native_home_resume').record(self)
    else
        local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.cancel(self) end
    end
    if weread_book_id then
        -- Always register the tap interception: even when annotations are hidden
        -- we must intercept taps on thought links to suppress the native footnote
        -- popup. Visibility is decided inside _onThoughtTap / applyAnnotationVisibility.
        self:_setupThoughtInterception()
    end
    if weread_book_id or require('weread.lib.native_direct_path').contains(self.settings,local_file) then
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
    if weread_book_id and self.settings:get("cache").show_annotations ~= false
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
    personal_action(self,'attach')

    local annotations_ready = perf("annotations_ready", opened)
    if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
    if self.source_navigation then self.source_navigation:cancel() end
    if self.source_close then self.source_close:on_reader_ready(weread_book_id) end
    if self.source_position then self.source_position:on_reader_ready() end
    self.progress_sync:on_reader_ready()
    self.read_report.on_source_changed=function(book_id)
        if self.progress_sync.current_book_id~=tostring(book_id) then return end
        self.progress_sync:checkpoint_local('source_remote_changed')
        self.progress_sync:_clear_verified('source_remote_changed')
        self.progress_sync.state='unverified'
    end
    if weread_book_id then require('weread.ui.chapter_links').attach(self) end
    if self.onTranslationReaderReady then self:onTranslationReaderReady() end
    local prefetch_session_gen = self._reader_session_gen
    UIManager:scheduleIn(0.2, function()
        if prefetch_session_gen ~= self._reader_session_gen then return end
        self:maybePrefetchNextChapter(weread_book_id)
    end)
    local _started, _title, reason = self.read_report:on_reader_ready()
    if self.offline_time then self.offline_time:resume() end
    local time_options=self.settings:get('offline_time',{})
    if type(time_options)=='table' and time_options.enabled==true and time_options.auto_native==true then
        local session=self._reader_session_gen;local epoch=self._native_auto_time_epoch
        UIManager:scheduleIn(.2,function()
            if self._reader_session_gen==session and self._native_auto_time_epoch==epoch and not self._weread_suspended then
                require('weread.lib.native_direct_time_auto').start(self)
            end
        end)
    end
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "auto" and reason == "document_not_weread" then
        self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
    end
    perf("reader_services", annotations_ready)
    perf("reader_ready_total", opened)
end

function M:onPageUpdate()
    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.view_changed(self) end
    local direct_online_search=package.loaded['weread.ui.native_direct_online_navigation'];if direct_online_search then direct_online_search.on_view_changed(self) end
    local direct_search=package.loaded['weread.ui.native_direct_search'];if direct_search then direct_search.on_view_changed(self) end
    local direct_search_open=package.loaded['weread.ui.native_direct_search_open'];if direct_search_open then direct_search_open.on_view_changed(self) end
    local direct_note=package.loaded['weread.ui.my_mark_navigation'];if direct_note and direct_note.on_view_changed then direct_note.on_view_changed(self) end
    local direct_position=package.loaded['weread.ui.native_direct_position'];if direct_position then direct_position.on_view_changed(self) end
    local direct_interval=package.loaded['weread.lib.native_direct_interval'];if direct_interval then direct_interval.on_view_changed(self) end
    local direct_cloud=package.loaded['weread.ui.native_direct_cloud_open'];if direct_cloud then direct_cloud.on_view_changed(self) end
    local reading_progress=package.loaded['weread.ui.reader_progress'];if reading_progress then reading_progress.cancel(self) end
    local translation_fetch=package.loaded['weread.ui.translation_fetch'];if translation_fetch then translation_fetch.view_changed(self) end
    local review=package.loaded['weread.ui.native_position_review'];if review then review.view_changed(self) end
    require('weread.ui.chapter_links').view_changed(self)
    personal_action(self,'update')
    selection_action(self,'view_changed')
    excerpt_action(self,'view_changed')
    if self._read_resume_token then require('weread.ui.read_resume').view_changed(self) end
    if self.onCloudSourceViewChanged then self:onCloudSourceViewChanged() end
    if self.source_navigation then self.source_navigation:on_view_changed() end
    if self.source_upload then self.source_upload:on_view_changed() end
    if self.source_position then self.source_position:on_view_changed() end
    self.progress_sync:on_page_update()
    if self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
end

function M:onPosUpdate()
    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.view_changed(self) end
    local direct_online_search=package.loaded['weread.ui.native_direct_online_navigation'];if direct_online_search then direct_online_search.on_view_changed(self) end
    local direct_search=package.loaded['weread.ui.native_direct_search'];if direct_search then direct_search.on_view_changed(self) end
    local direct_search_open=package.loaded['weread.ui.native_direct_search_open'];if direct_search_open then direct_search_open.on_view_changed(self) end
    local direct_note=package.loaded['weread.ui.my_mark_navigation'];if direct_note and direct_note.on_view_changed then direct_note.on_view_changed(self) end
    local direct_position=package.loaded['weread.ui.native_direct_position'];if direct_position then direct_position.on_view_changed(self) end
    local direct_interval=package.loaded['weread.lib.native_direct_interval'];if direct_interval then direct_interval.on_view_changed(self) end
    local direct_cloud=package.loaded['weread.ui.native_direct_cloud_open'];if direct_cloud then direct_cloud.on_view_changed(self) end
    local reading_progress=package.loaded['weread.ui.reader_progress'];if reading_progress then reading_progress.cancel(self) end
    local translation_fetch=package.loaded['weread.ui.translation_fetch'];if translation_fetch then translation_fetch.view_changed(self) end
    local review=package.loaded['weread.ui.native_position_review'];if review then review.view_changed(self) end
    require('weread.ui.chapter_links').view_changed(self)
    personal_action(self,'update')
    selection_action(self,'view_changed')
    excerpt_action(self,'view_changed')
    if self._read_resume_token then require('weread.ui.read_resume').view_changed(self) end
    if self.onCloudSourceViewChanged then self:onCloudSourceViewChanged() end
    if self.source_navigation then self.source_navigation:on_view_changed() end
    if self.source_upload then self.source_upload:on_view_changed() end
    if self.source_position then self.source_position:on_view_changed() end
    self.progress_sync:on_page_update()
    if self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
end

function M:onCloseDocument()
    local home_resume=package.loaded['weread.ui.native_home_resume']
    if home_resume then
        pcall(home_resume.record_closed,self)
        home_resume.cancel(self)
    end
    local reconnect=package.loaded['weread.ui.native_direct_reconnect']
    if reconnect then
        if reconnect.checkpoint(self)==false and self.showTransientInfo then
            self:showTransientInfo(_('Could not save the offline sync reminder. Your local reading page is kept.'),3)
        end
        reconnect.cancel(self)
    end
    local native_cleanup=package.loaded['weread.ui.native_direct_cleanup'];if native_cleanup then native_cleanup.cancel(self) end
    local copy_resume=package.loaded['weread.ui.native_direct_copy_resume'];if copy_resume then copy_resume.cancel(self) end
    local image_refresh=package.loaded['weread.ui.native_direct_image_refresh'];if image_refresh then image_refresh.cancel(self) end
    self._native_auto_time_epoch=(self._native_auto_time_epoch or 0)+1
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.cancel(self) end
    local direct_note=package.loaded['weread.ui.my_mark_navigation'];if direct_note and direct_note.cancel_incoming then direct_note.cancel_incoming(self) end
    local direct_close=package.loaded['weread.lib.native_direct_close']
    if self._native_direct_interval and not direct_close then direct_close=require('weread.lib.native_direct_close') end
    local direct_close_token
    if direct_close then
        local captured,token=pcall(direct_close.freeze,self)
        if captured then direct_close_token=token end
    end
    local direct_interval=package.loaded['weread.lib.native_direct_interval'];if direct_interval then direct_interval.cancel(self) end
    local direct_navigation=package.loaded['weread.ui.native_direct_navigation']
    if direct_navigation then direct_navigation.cancel(self) end
    local native_direct=package.loaded['weread.ui.native_direct_reading']
    if native_direct then native_direct.cancel(self) end
    local direct_position=package.loaded['weread.ui.native_direct_position']
    if direct_position then direct_position.cancel(self) end
    local direct_cloud=package.loaded['weread.ui.native_direct_cloud_open']
    if direct_cloud then direct_cloud.cancel(self) end
    local direct_search_open=package.loaded['weread.ui.native_direct_search_open']
    if direct_search_open then direct_search_open.cancel(self) end
    local direct_online_search=package.loaded['weread.ui.native_direct_online_navigation']
    if direct_online_search then direct_online_search.cancel(self) end
    local reading_progress=package.loaded['weread.ui.reader_progress'];if reading_progress then reading_progress.cancel(self) end
    local typography=package.loaded['weread.ui.reader_typography'];if typography then typography.cancel(self) end
    local display=package.loaded['weread.ui.reader_display'];if display then display.cancel(self) end
    require('weread.ui.prefetch_auth_recovery').cancel(self)
    self._prefetch_auth_attempts=nil
    self._resume_chapter_prefetch=nil
    self._chapter_open_intent=nil
    if self._native_account_location then require('weread.lib.native_account_location').before_close(self) end
    local review=package.loaded['weread.ui.native_position_review'];if review then review.cancel(self) end
    require('weread.ui.chapter_links').detach(self)
    require('weread.lib.rich_footnotes').detach(self)
    if self.closeOfflineTimeUI then self:closeOfflineTimeUI() end
    personal_action(self,'detach')
    selection_action(self,'detach')
    excerpt_action(self,'detach')
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
    if self.cancelMPLink then self:cancelMPLink() end
    if self.cancelPersonalUpload then self:cancelPersonalUpload() end
    if self.cancelPersonalOriginal then self:cancelPersonalOriginal() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelShelfState then self:cancelShelfState() end
    if self.closeReadingLanguageDocument then self:closeReadingLanguageDocument() end
    if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
    if self.cancelBookSearch then self:cancelBookSearch() end
    if self.cancelLocalNotesExport then self:cancelLocalNotesExport() end
    if self.closeReaderLinkUI then self:closeReaderLinkUI() end
    if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
    if self.cancelProfileRefresh then self:cancelProfileRefresh() end
    if self.cancelReadStatsRequest then self:cancelReadStatsRequest() end
    if self.cancelBookMetadata then self:cancelBookMetadata() end
    if self.cancelBookReading then self:cancelBookReading() end
    require('weread.ui.catalog_request').cancel(self)
    require('weread.ui.download_recovery').cancel(self)
    if self.cancelDiscoveryRequest then self:cancelDiscoveryRequest() end
    if self.source_navigation then self.source_navigation:cancel() end
    local source_position = self.source_position and self.source_position:current()
    local close_token,close_position = self.progress_sync:prepare_close(source_position)
    if self.source_position then self.source_position:stop() end
    if self.native_renewal then self.native_renewal:cancel() end
    if self.cancelShelfRefresh then self:cancelShelfRefresh() end
    if self.native_authorization then self.native_authorization:cancel() end
    if self.offline_time then self.offline_time:stop("no_book") end
    local time_source=package.loaded['weread.lib.native_direct_offline_time'];if time_source then time_source.cancel(self) end
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
    self._weread_book_route = nil
    self:_teardownThoughtInterception()
    self:_teardownXPointerOverlayPrototype()
    self:_removeReaderHighlightTapGuard()

    if self._orig_onEndOfBook and self.ui.status then
        self.ui.status.onEndOfBook = self._orig_onEndOfBook
        self._orig_onEndOfBook = nil
    end

    self.read_report:on_close_document()
    if direct_close_token then
        local started=pcall(direct_close.start,self,direct_close_token)
        if not started then pcall(direct_close.cancel,self) end
    end
end

function M:onShowingReader()
    local direct_close=package.loaded['weread.lib.native_direct_close'];if direct_close then direct_close.cancel(self) end
    require('weread.ui.catalog_request').cancel(self)
    require('weread.ui.download_recovery').cancel(self)
    if self.cancelBookReading then self:cancelBookReading() end
    require('weread.ui.mp_file_open').cancel(self)
    require('weread.ui.mp_reader_open').cancel(self)
end

function M:onCloseWidget()
    local covers=package.loaded['weread.lib.shelf_cover_bitmap_cache'];if covers then covers.clear() end
    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.cancel(self) end
    local native_cleanup=package.loaded['weread.ui.native_direct_cleanup'];if native_cleanup then native_cleanup.cancel(self) end
    local copy_resume=package.loaded['weread.ui.native_direct_copy_resume'];if copy_resume then copy_resume.cancel(self) end
    local image_refresh=package.loaded['weread.ui.native_direct_image_refresh'];if image_refresh then image_refresh.cancel(self) end
    self._native_auto_time_epoch=(self._native_auto_time_epoch or 0)+1
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.cancel(self) end
    local home_resume=package.loaded['weread.ui.native_home_resume'];if home_resume then home_resume.cancel(self) end
    require('weread.ui.prefetch_auth_recovery').cancel(self)
    require('weread.ui.catalog_request').cancel(self)
    require('weread.ui.download_recovery').cancel(self)
    local offline=package.loaded['weread.ui.finish_offline']
    if offline then offline.cancel_sync(self);offline.cancel_dialog(self) end
    local member=package.loaded['weread.ui.membership_offline'];if member then member.cancel_sync(self);member.cancel_dialog(self) end
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

local function chapter_in_catalog(chapters, uid)
    if uid then
        uid = tostring(uid)
        for index, chapter in ipairs(chapters) do
            if type(chapter) == "table" and tostring(chapter.chapterUid or chapter.chapterId or "") == uid then
                return index, chapter
            end
        end
    end
end

function M:maybePrefetchNextChapter(book_id, recovered)
    local cache = self.settings:get("cache")
    if cache.auto_prefetch_next_chapter ~= true or not book_id then
        self.downloader:cancelPrefetch("prefetch_not_applicable")
        return false
    end

    local book,identity_error = ReadAccess.load_cached_book(self.settings, book_id)
    if identity_error then
        local active=self.downloader.getActivePrefetch and self.downloader:getActivePrefetch()
        local selected=active and active.book and active.chapters and active.chapters[1]
            and self.downloader:isPromotedPrefetch(active.book,active.chapters[1])
        self.downloader:cancelPrefetch('book_identity_handled')
        if selected then self:showInfo(book_identity_message()) else self:showPrefetchNotice(book_identity_message()) end
        return false
    end
    local file = self.ui and self.ui.document and self.ui.document.file
    if not book or not file then
        self.downloader:cancelPrefetch("prefetch_context_missing")
        return false
    end
    local Claims=require('weread.lib.chapter_cache_claim')
    local current_uid, shared = Claims.mapped_chapter(book, file)
    if shared then
        local info = Claims.inspect(book, file, nil, true)
        current_uid = info.kind == "single" and info.uid or nil
    end
    if not current_uid or current_uid == "" then
        self.downloader:cancelPrefetch("no_next_chapter")
        return false
    end

    local chapters = self:ensureChaptersLoaded(book, true)
    if not chapters then
        self.downloader:cancelPrefetch("prefetch_context_missing")
        return false
    end
    local current_index = chapter_in_catalog(chapters, current_uid)
    local next_chapter = current_index and chapters[current_index + 1]
    local next_uid = type(next_chapter) == "table" and tostring(next_chapter.chapterUid or next_chapter.chapterId or "")
    if not next_uid or next_uid == "" or next_uid == current_uid then
        self.downloader:cancelPrefetch("no_next_chapter")
        return false
    end

    if recovered then
        if recovered.chapter_uid~=next_uid or FileIdentity.version(book.bookVersion)~=recovered.previous_version
            or not require('weread.ui.prefetch_auth_recovery').matches(recovered.chapter,next_chapter) then return false end
        local copied={};for key,value in pairs(book) do copied[key]=value end
        copied.bookVersion=recovered.version;book=copied
    end
    local cached = ReadAccess.cached_chapter(book.cached_chapters, next_uid)
    if cached ~= file and file_exists(cached) then
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
            local retry_requested, retry_current = self.downloader:isPromotedPrefetch(
                book, next_chapter)
            if value == "cancelled" or value == "document_closed"
                or value == "replaced" or value == "manual_download"
                or value == "setting_disabled" or value == "prefetch_not_applicable"
                or value == "prefetch_context_missing" or value == "no_next_chapter"
                or value == "next_chapter_cached" or value == 'account_changed' or value == 'suspended'
                or value == 'book_identity_handled' then
                logger.info("ended without completion:",
                    "book_id=", tostring(book_id),
                    "chapter_uid=", next_uid,
                    "title=", title,
                    "reason=", tostring(value))
                return
            end
            if value == 'rate_limited' and retry_requested then
                self:showInfo(_('WeRead is limiting requests. Download stopped. Please try again later.'))
                return
            end
            if value=='book_identity_conflict' or value=='download_cache_unavailable' then
                local message=value=='book_identity_conflict' and book_identity_message()
                    or _("Could not save book information. Check storage and try again.")
                if retry_requested then self:showInfo(message) else self:showPrefetchNotice(message) end
                return
            end
            if value=='web_expired' and not retry_requested
                and require('weread.ui.prefetch_auth_recovery').start(self,book,next_chapter) then return end
            local reason = value == "offline" and _("Network is not connected")
                or value == 'web_expired' and _('WeRead login expired. Please sign in again and retry.')
                or value == 'native_auth_expired' and _('E-Ink authorization expired. Sign in again or turn off experimental E-Ink resources.')
                or value == 'native_resource_failed' and _('Experimental E-Ink resources could not be downloaded. Try again later or turn them off.')
                or value == 'rate_limited' and _('WeRead is limiting requests. Please try again later.')
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
            if retry_requested and (value=='native_auth_expired' or value=='native_resource_failed') then
                self:showInfo(reason)
                return
            end
            if retry_requested then
                local source_file = file
                local retry_cache = self.settings:get("cache")
                local retry_delay = retry_cache.show_prefetch_notifications == false
                    and 0.1 or 1.1
                UIManager:scheduleIn(retry_delay, function()
                    if self.ui.document and self.ui.document.file == source_file
                        and (not retry_current or retry_current()) then
                        self:downloadChapterAndRead(book, next_chapter, nil, retry_current)
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
    local covers=package.loaded['weread.lib.shelf_cover_bitmap_cache'];if covers then covers.clear() end
    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.suspend(self) end
    if self._weread_suspended then return end
    self._weread_suspended=true
    local downloads=package.loaded['weread.ui.download_library'];if downloads then downloads.cancel(self) end
    local native_direct=package.loaded['weread.ui.native_direct_reading'];if native_direct then native_direct.cancel(self) end
    local native_cleanup=package.loaded['weread.ui.native_direct_cleanup'];if native_cleanup then native_cleanup.cancel(self) end
    local copy_resume=package.loaded['weread.ui.native_direct_copy_resume'];if copy_resume then copy_resume.cancel(self) end
    local image_refresh=package.loaded['weread.ui.native_direct_image_refresh'];if image_refresh then image_refresh.cancel(self) end
    self._native_auto_time_epoch=(self._native_auto_time_epoch or 0)+1
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.cancel(self) end
    local home_resume=package.loaded['weread.ui.native_home_resume'];if home_resume then home_resume.suspend(self) end
    local direct_close=package.loaded['weread.lib.native_direct_close'];if direct_close then direct_close.cancel(self) end
    local direct_interval=package.loaded['weread.lib.native_direct_interval'];if direct_interval then direct_interval.cancel(self) end
    local direct_position=package.loaded['weread.ui.native_direct_position'];if direct_position then direct_position.cancel(self) end
    local reading_progress=package.loaded['weread.ui.reader_progress'];if reading_progress then reading_progress.cancel(self) end
    local typography=package.loaded['weread.ui.reader_typography'];if typography then typography.cancel(self) end
    local display=package.loaded['weread.ui.reader_display'];if display then display.cancel(self) end
    local screenshot=package.loaded['weread.ui.delayed_screenshot'];if screenshot then screenshot.cancel() end
    local renewing=require('weread.ui.prefetch_auth_recovery').cancel(self)
    self._chapter_open_intent=nil
    self._resume_chapter_prefetch=nil
    if self.downloader and (self.downloader:cancelPrefetch('suspended') or renewing) then
        self._resume_chapter_prefetch={book_id=self._current_weread_book_id,session=self._reader_session_gen,
            scope=self.settings.get_auth_scope and self.settings:get_auth_scope()}
    end
    require('weread.ui.catalog_request').cancel(self)
    require('weread.ui.download_recovery').cancel(self)
    local offline=package.loaded['weread.ui.finish_offline']
    if offline then offline.cancel_sync(self);offline.cancel_dialog(self) end
    local member=package.loaded['weread.ui.membership_offline'];if member then member.cancel_sync(self);member.cancel_dialog(self) end
    local review=package.loaded['weread.ui.native_position_review'];if review then review.cancel(self) end
    require('weread.ui.chapter_links').cancel(self)
    if self.closeOfflineTimeUI then self:closeOfflineTimeUI() end
    personal_action(self,'suspend')
    selection_action(self,'cancel')
    excerpt_action(self,'cancel')
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
    if self.cancelMPLink then self:cancelMPLink() end
    if self.cancelPersonalUpload then self:cancelPersonalUpload() end
    if self.cancelPersonalOriginal then self:cancelPersonalOriginal() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelShelfState then self:cancelShelfState() end
    if self.cancelReadingLanguage then self:cancelReadingLanguage() end
    if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
    if self.cancelBookSearch then self:cancelBookSearch() end
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
    self._weread_suspended=nil
    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.connected(self) end
    local home_resume=package.loaded['weread.ui.native_home_resume'];if home_resume then home_resume.resume(self) end
    local pending=self._resume_chapter_prefetch;self._resume_chapter_prefetch=nil
    if pending then
        UIManager:scheduleIn(.2,function()
            if pending.book_id and self._current_weread_book_id==pending.book_id
                and self._reader_session_gen==pending.session and pending.scope
                and self.settings:auth_scope_matches(pending.scope) then self:maybePrefetchNextChapter(pending.book_id) end
        end)
    end
    personal_action(self,'wake')
    if self.resumeShelfCovers then self:resumeShelfCovers() end
    self.progress_sync:on_resume()
    if self.source_position then self.source_position:resume("suspend") end
    self.read_report:on_resume()
    if self.offline_time then self.offline_time:resume() end
    local auto_time=package.loaded['weread.lib.native_direct_time_auto']
    local time_options=self.settings:get('offline_time',{})
    if not auto_time and type(time_options)=='table' and time_options.enabled==true and time_options.auto_native==true then
        auto_time=require('weread.lib.native_direct_time_auto')
    end
    if auto_time then auto_time.start(self) end
    require('weread.ui.finish_offline').pump(self)
    require('weread.ui.membership_offline').pump(self)
    if self.startHomeStatusTimer and self.shelf_view and self.shelf_view.home_layout then
        self:startHomeStatusTimer(self.shelf_view)
    end
end

function M:onReadingPaused()
    if self.offline_time then self.offline_time:pause() end
end

function M:onReadingResumed()
    if self.offline_time then self.offline_time:resume() end
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.start(self) end
end

function M:onNetworkConnected()
    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.connected(self) end
    personal_action(self,'network_connected')
    if self.progress_sync then self.progress_sync:on_network_connected() end
    if self.offline_time then self.offline_time:update("network_connected", true) end
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.start(self) end
    require('weread.ui.finish_offline').pump(self)
    require('weread.ui.membership_offline').pump(self)
end

function M:onNetworkDisconnected()
    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.disconnected(self) end
    local image_refresh=package.loaded['weread.ui.native_direct_image_refresh'];if image_refresh then image_refresh.cancel(self) end
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.cancel(self) end
    local direct_close=package.loaded['weread.lib.native_direct_close'];if direct_close then direct_close.cancel(self) end
    local direct_interval=package.loaded['weread.lib.native_direct_interval'];if direct_interval then direct_interval.cancel(self) end
    local direct_position=package.loaded['weread.ui.native_direct_position'];if direct_position then direct_position.cancel(self) end
    local offline=package.loaded['weread.ui.finish_offline'];if offline then offline.cancel_sync(self) end
    local member=package.loaded['weread.ui.membership_offline'];if member then member.cancel_sync(self) end
    local review=package.loaded['weread.ui.native_position_review'];if review then review.cancel(self) end
    if self.progress_sync then self.progress_sync:on_network_disconnected() end
    if self.offline_time then self.offline_time:update("network_disconnected", false) end
end

local function remember_book_route(host, file, book_id, indexes, auth_epoch, expected_directory)
    local index = indexes and indexes[book_id]
    local root = type(index) == "table" and index.cache_dir
    if type(root) ~= "string" or root == "" then return end
    local directory = root:gsub("/+$", "") .. "/"
    if #directory <= 1 or expected_directory ~= directory or file:sub(1, #directory) ~= directory then return end
    local settings = host.settings
    host._weread_book_route = { document = host.ui.document, file = file, book_id = book_id, settings = settings, indexes = indexes,
        cache_dir = settings.cache_dir, book_dir = root, auth_epoch = auth_epoch }
end

function M:detectWeReadBook()
    local document = self.ui.document
    local file = document and document.file
    if not file then
        return nil
    end
    if require('weread.lib.native_direct_path').contains(self.settings,file) then return nil end
    if self._personal_original_local_only==file then return nil end
    if require("weread.lib.notes_export").is_export_path(self.settings,file) then return nil end
    if require("weread.lib.mp_export").is_export_path(self.settings,file) then return nil end
    local settings = self.settings
    local indexes = type(settings.get_book_indexes) == "function" and settings:get_book_indexes()
    if type(indexes) ~= "table" then indexes = nil end
    local auth_epoch = indexes and settings:get("auth_epoch", 0)
    local route = self._weread_book_route
    if route and route.document == document and route.file == file and route.settings == settings and route.indexes == indexes
        and route.cache_dir == settings.cache_dir and route.auth_epoch == auth_epoch then
        local index = indexes[route.book_id]
        if type(index) == "table" and index.cache_dir == route.book_dir then return route.book_id end
    end
    self._weread_book_route = nil
    local book_id, directory, evidence
    if type(settings.find_book_by_file) == "function" then
        book_id, directory, evidence = settings:find_book_by_file(file)
    else
        book_id, directory, evidence = require('weread.lib.book_store').find_file(settings, settings:get("books", {}), file)
    end
    if evidence == 'ambiguous' then return nil end
    if book_id ~= nil then
        if evidence == 'directory' then remember_book_route(self, file, book_id, indexes, auth_epoch, directory) end
        return book_id
    end

    -- Require a path boundary after the cache directory.
    local prefix = settings.cache_dir:gsub("/+$", "") .. "/"
    if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        return rest:match("^([^/]+)/")
    end
    return nil
end

function M:ensureChaptersLoaded(book, read_only)
    if not book then return nil end
    if type(book.chapters) == "table" and #book.chapters > 0 then
        if read_only then return book.chapters end
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
        if self.library_db and not read_only then
            self.library_db:putChapters(book_id, chapters)
        end
        return chapters
    end

    chapters = self.library_db and self.library_db:getChapters(book_id) or nil
    if type(chapters) == "table" and #chapters > 0 then
        book.chapters = chapters
        if read_only then return chapters end
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
-- recently downloaded single chapter. Shared mappings need archive evidence
-- before the file can be treated as a combined book.
function M:getFullBookCachePath(book, exists, claim_cache)
    if type(book) ~= "table" then return nil end
    local Claims=require('weread.lib.chapter_cache_claim')
    local full = book.cached_full_book
    local legacy = book.cached_file
    -- Sharing checks here only need the two candidate paths. Share any EPUB
    -- proof with the caller without building a map of all downloaded files.
    if type(full) == "string" and full ~= "" and (exists or file_exists)(full) then
        if not Claims.shared(book,full)
            or Claims.inspect(book,full,claim_cache,true).kind=='combined' then return full end
        if legacy == full then return nil end
    end
    if type(legacy) ~= "string" or legacy == "" then return nil end
    if book.cached_chapters and type(book.cached_chapters) ~= "table" then return nil end
    local shared,mapped=Claims.shared(book,legacy)
    if shared then
        return Claims.inspect(book,legacy,claim_cache,true).kind=='combined' and legacy or nil
    end
    if mapped then return nil end
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
--   partial_combined (boolean): The combined file does not match the full catalog, or could not be verified.
--   proof (table or nil): Archive evidence for a combined file.
function M:getChapterInfoFromFile(book, file_path)
    if not book or not file_path or type(book.chapters) ~= "table" then
        return nil, nil, false
    end

    local Claims=require('weread.lib.chapter_cache_claim')
    local current_uid,shared=Claims.mapped_chapter(book,file_path)
    local function complete(info)
        local document=self.ui and self.ui.document
        return Claims.document_complete(info,document,book.book_id or book.bookId,book.chapters)
    end
    local claim_cache = shared and {} or nil
    local full_book_path = self:getFullBookCachePath(book,nil,claim_cache)
    if full_book_path == file_path then
        local info=Claims.combined(book,file_path,claim_cache)
        return nil,nil,true,not complete(info),info
    end

    if shared then
        local info=Claims.inspect(book,file_path,nil,true)
        if info.kind=='combined' then return nil,nil,true,not complete(info),info end
        if info.kind~='single' then return nil,nil,false end
        current_uid=info.uid
    end

    local index, chapter = chapter_in_catalog(book.chapters, current_uid)
    return index, chapter, false
end

function M:onFlushSettings()
    if self.progress_sync then self.progress_sync:checkpoint_local("settings_flush") end
    if self.settings then
        self.settings:flush()
    end
end

return M
