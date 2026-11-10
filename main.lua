local logger = require("weread.lib.logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Client = require("weread.lib.client")
local BackgroundWorker = require("weread.lib.background_worker")
local Content = require("weread.lib.content")
local Downloader = require("weread.lib.downloader")
local ExternalAnnotationsDB = require("weread.lib.external_annotations_db")
local Integrations = require("integrations.init")
local LibraryDB = require("weread.lib.library_db")
local Mixin = require("weread.lib.mixin")
local Migrations = require("weread.lib.migrations")
local NativeAuthorization = require("weread.ui.native_authorization")
local NativeRenewal = require("weread.lib.native_renewal")
local OfflineTime = require("weread.lib.offline_time")
local PluginUtil = require("weread.lib.plugin_util")
local ProgressSync = require("weread.lib.progress_sync")
local ProgressSyncDialog = require("weread.ui.progress_sync_dialog")
local QRLogin = require("weread.lib.qr_login")
local ReadReport = require("weread.lib.read_report")
local ReadtimeCoverage = require("weread.lib.readtime_coverage")
local ReaderPosition = require("weread.lib.reader_position")
local Settings = require("weread.lib.settings")
local SourcePosition = require("weread.lib.source_position")
local SourceNavigation = require("weread.lib.source_navigation")
local Updater = require("weread.lib.updater")
local UpdaterUI = require("weread.ui.updater")

local _ = PluginUtil.tr

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = "1.7.0",
}

-- Stable entry point used by third-party launchers such as SimpleUI and ZenUI.
function WeReadPlugin:openBookshelf()
    return self:showBookshelf()
end

-- Both SimpleUI and ZenUI discover conventional plugin launch methods.
function WeReadPlugin:launch()
    return self:showHome()
end

function WeReadPlugin:onZenUIReady()
    Integrations.onZenUIReady(self)
    return true
end

function WeReadPlugin:init()
    math.randomseed(os.time())
    self.settings = Settings:new()
    self.external_annotations_db = ExternalAnnotationsDB:new(self.settings)
    self.library_db = LibraryDB:new(self.settings)
    self.readtime_coverage = ReadtimeCoverage:new(self.settings.data_dir)
    self.readtime_coverage:initialize()
    self.offline_time = OfflineTime:new{
        settings = self.settings, library_db = self.library_db, scheduler = UIManager,
        get_context = function()
            local document = self.ui and self.ui.document
            return document and { book_id = self:detectWeReadBook(), path = document.file,
                document = document, stats = self.ui.statistics,
                visible = UIManager:getTopmostVisibleWidget() == self.ui } or nil
        end,
        is_online = function() return self:isNetworkConnected() end,
    }
    local updater = Updater:new{
        settings = self.settings,
        current_version = self.version,
    }
    self.updater = UpdaterUI:new{
        updater = updater,
        settings = self.settings,
        is_connected = function()
            return self:isNetworkConnected()
        end,
        refresh_ui = function()
            self:refreshUI()
        end,
    }
    self.client = Client:new(self.settings)
    self.prefetch_worker = BackgroundWorker:new{
        temp_dir = self.settings.data_dir .. "/workers",
        -- A soft launch gate, not a reservation: fork uses copy-on-write and
        -- normally consumes far less than this on a 512 MB Kindle.
        min_available_kb = 64 * 1024,
    }
    self.downloader = Downloader:new{
        client = self.client,
        settings = self.settings,
        background_worker = self.prefetch_worker,
        show_info       = function(text) self:showInfo(text) end,
        show_transient  = function(text, timeout) self:showTransientInfo(text, timeout) end,
        refresh_ui      = function() self:refreshUI() end,
        refresh_shelf   = function() self:refreshShelfCacheIndicators() end,
        open_file       = function(path, book) self:openFile(path,nil,book) end,
        safe_callback   = function(label, fn) return self:safeCallback(label, fn) end,
        require_login   = function(cookie, api_key) return self:requireLogin(cookie, api_key) end,
        run_online_task = function(label, fn)
            return self:runOnlineTask(label, fn)
        end,
        is_connected = function()
            return self:isNetworkConnected()
        end,
    }
    Migrations.run(self.settings, self.client)
    self.external_annotations_db:migrateLegacySettings()
    if self.downloader.recover then
        self.downloader:recover()
    end
    self.qr_login = QRLogin:new(self, self.client, self.settings)
    self.native_renewal = NativeRenewal:new{ settings = self.settings, client = self.client, scheduler = UIManager }
    self.native_authorization = NativeAuthorization:new(self, self.client, self.settings)
    self.shelf_membership = require('weread.lib.shelf_membership_service'):new{
        settings=self.settings,client=self.client,scheduler=UIManager}
    self.source_dispatch = require("weread.lib.source_dispatch"):new{settings=self.settings}
    self.read_report = ReadReport:new{
        source_dispatch = self.source_dispatch,
        coverage = self.readtime_coverage,
        settings = self.settings,
        client = self.client,
        library_db = self.library_db,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        position_provider = function(book_id)
            if not self.progress_sync then
                return nil, "progress_sync_initializing", true
            end
            return self.progress_sync:position_for_report(book_id)
        end,
        position_preparer = function(position,callback) return self.source_upload:prepare(position,callback) end,
        on_source_confirmed = function(remote)
            if self.progress_sync then self.progress_sync:accept_report_confirmation(remote) end
        end,
        on_source_unconfirmed = function()
            if self.progress_sync then
                self.progress_sync.dirty=true
                self.progress_sync:checkpoint_local("upload_readback_unconfirmed")
                self.progress_sync:_clear_verified("upload_readback_unconfirmed")
            end
        end,
        -- The report tick runs on the UI loop; use the link-state check here
        -- because NetworkMgr:isOnline() does a blocking DNS lookup.
        is_online = function()
            return self:isNetworkConnected()
        end,
    }
    self.source_recovery = require("weread.lib.source_recovery"):new{settings=self.settings,
        renew=function(options,callback) return require('weread.ui.web_renewal').run(self,options,callback) end,
        cancel=function(handle) require('weread.ui.web_renewal').cancel(self,handle) end,
        can_recover=function(book_id) return not self.source_dispatch:pending(book_id) end}
    self.source_position = SourcePosition:new{
        recovery = self.source_recovery,
        on_auth_failure = function(book_id)
            if self.progress_sync and self.progress_sync.current_book_id==book_id and self.progress_sync.verified then
                self.progress_sync:_clear_verified('source_authentication_unavailable')
                self.progress_sync.notify('upload_failed',{error='source_authentication_unavailable'})
            end
        end,
        scheduler = UIManager, codec = self.client,
        client = self.client, is_online = function() return self:isNetworkConnected() end,
        get_document = function() return self.ui and self.ui.document end,
        get_book_id = function() return self._current_weread_book_id end,
        get_account = function() return self.settings:get("account", {}).user_vid end,
        get_mode = function() return self.ui and self.ui.view and self.ui.view.view_mode end,
        get_retained = function() return self.progress_sync and self.progress_sync:current_source_target() end,
        get_upload_context = function()
            if not self.progress_sync then return nil end
            local position, reason, context = self.progress_sync:capture_local()
            if not position then return nil,reason end
            local book = self.settings:get("books", {})[position.book_id]
            if not book or not context then return nil end
            local chapters
            if self.library_db then chapters=self.library_db:getChapters(position.book_id)
            else chapters=book.chapters end
            return type(chapters)=="table" and #chapters>0
                and {book_id=position.book_id,percent=position.percent,chapters=chapters} or nil
        end,
        get_viewport_height = function() return self.progress_sync and self.progress_sync.get_viewport_height() end,
        is_busy = function()
            local highlight = self.ui and self.ui.highlight
            return highlight and (highlight.selected_text ~= nil or highlight.select_mode == true) or false
        end,
        can_prepare = function()
            if self.downloader and self.downloader._active_job then return false end
            if self.prefetch_worker and self.prefetch_worker:busy() then return false end
            local available = self.prefetch_worker and self.prefetch_worker:availableMemoryKB()
            return not available or available >= 64 * 1024
        end,
        on_change = function(state, position)
            if state ~= "ready" and self.closeReadingPositionMessage then self:closeReadingPositionMessage() end
            if self.progress_sync then self.progress_sync:on_source_position_changed(state, position) end
        end,
    }
    self.source_upload = require("weread.lib.source_upload"):new{source=self.source_position,scheduler=UIManager}
    self.source_close = require("weread.lib.source_close"):new{source=self.source_position,scheduler=UIManager,
        get_catalog=function(book_id)
            if self.library_db then return self.library_db:getChapters(book_id) end
            local book=self.settings:get("books",{})[book_id]
            return book and book.chapters
        end}
    self.progress_sync = ProgressSync:new{
        recovery = self.source_recovery,
        source_dispatch = self.source_dispatch,
        settings = self.settings,
        client = self.client,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        get_source_position = function() return self.source_position:current() end,
        get_navigation_xpointer = function() return self.ui and self.ui.rolling and self.ui.rolling.xpointer end,
        on_before_navigate = function()
            if self._read_resume_token then require('weread.ui.read_resume').cancel(self) end
            if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
            if self.source_navigation then self.source_navigation:cancel() end
        end,
        get_viewport_height = function()
            local view = self.ui and self.ui.view
            if not view or not view.dimen then return nil end
            local footer = view.footer
            local reserved = view.footer_visible and footer and not (footer.settings and footer.settings.reclaim_height)
            return view.dimen.h - (reserved and footer:getHeight() or 0)
        end,
        get_footer = function()
            return self.ui and self.ui.view and self.ui.view.footer
        end,
        get_view_mode = function()
            return self.ui and self.ui.view and self.ui.view.view_mode
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        get_book = function(book_id)
            return self.settings:get("books", {})[tostring(book_id)]
        end,
        get_chapters = function(book)
            return self:ensureChaptersLoaded(book)
        end,
        refresh_catalog = function(book_id)
            local book = self.settings:get("books", {})[tostring(book_id)]
            if type(book) ~= "table" then
                return nil, "book_not_found"
            end
            local ok, chapters_or_err = pcall(function()
                Content.ensure_reader_state(self.client, book)
                return Content.fetch_catalog(self.client, book)
            end)
            if not ok then
                return nil, chapters_or_err
            end
            local chapters = chapters_or_err
            if type(chapters) ~= "table" or #chapters == 0 then
                return nil, "catalog_unavailable"
            end
            local cache_ok, cache_err = Content.save_catalog_cache(
                self.client, self.settings, book, chapters)
            if not cache_ok then
                logger.warn("save chapter catalog cache failed:",
                    PluginUtil.log_error(cache_err))
            end
            if self.library_db then
                self.library_db:putChapters(book_id, chapters)
            end
            return chapters
        end,
        get_file_context = function(book, path)
            return self:getChapterInfoFromFile(book, path)
        end,
        run_online = function(_kind, callback, run_options)
            return self:runOnlineTask(
                _("Sync progress"), callback, nil, run_options)
        end,
        prepare_upload = function(position,callback) return self.source_upload:prepare(position,callback) end,
        cancel_upload_preparation = function() return self.source_upload:cancel() end,
        is_report_busy = function() return self.read_report.job~=nil or self.read_report.preparation~=nil end,
        freeze_close = function(position) return self.source_close:freeze(position) end,
        prepare_closed = function(token,position,callback) return self.source_close:prepare(token,position,callback) end,
        apply_source_remote = function() return self:showCloudSourcePosition(true) end,
        upload_position = function(book_id, position, elapsed_seconds, plan)
            return self.read_report:upload_position(
                book_id, position, elapsed_seconds, plan)
        end,
        confirm_position = function(receipt)
            return self.read_report:confirm_position(receipt)
        end,
        goto_fraction = function(fraction)
            return ReaderPosition.goto_fraction(self.ui, fraction)
        end,
        open_chapter = function(book, chapter)
            return self:openProgressTargetChapter(book, chapter)
        end,
        is_online = function()
            return self:isNetworkConnected()
        end,
        on_choice = function(context)
            ProgressSyncDialog.show_choice(context)
        end,
        notify = function(code, data)
            ProgressSyncDialog.notify(code, data)
        end,
    }
    self.source_navigation = SourceNavigation:new{
        scheduler = UIManager, codec = self.client,
        get_document = self.source_position.get_document,
        get_book_id = self.source_position.get_book_id,
        get_account = self.source_position.get_account,
        get_mode = self.source_position.get_mode,
        get_viewport_height = self.progress_sync.get_viewport_height,
        can_prepare = self.source_position.can_prepare,
        is_busy = self.source_position.is_busy,
        navigate = function(xpointer) return ReaderPosition.goto_xpointer(self.ui, xpointer) end,
        on_start = function()
            self.progress_sync:begin_local_navigation()
            self.source_position:pause("source_jump")
        end,
        on_done = function() self.source_position:resume("source_jump") end,
        on_cancel = function(job)
            require("weread.ui.cloud_source").navigation_cancelled(self, job)
            if self._read_resume_active then require('weread.ui.read_resume').navigation_cancelled(self,job) end
        end,
        on_applied = function(position, xpointer, metadata)
            return self.progress_sync:retain_source_target(position, xpointer, metadata)
        end,
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.integrations = Integrations
    self.integrations.register(self)
    local read_report = self.settings:get("read_report")
    if read_report.enabled
        and read_report.mode == "manual"
        and read_report.book_id ~= ""
        and read_report.report_on_open == false then
        self.read_report:maybe_start("plugin_start")
    end
    self._reader_session_gen = 0
    self.updater:schedule_auto_check()
    require('weread.ui.mp_file_open').attach(self)
    require('weread.ui.mp_reader_open').attach(self)
    require('weread.ui.mp_metadata_preview').attach(self)
    logger.info("initialized:", "version=", self.version)
    updater:cleanup_backup()
end

Mixin.apply(WeReadPlugin, {
    (require("weread.ui.common")),
    (require("weread.ui.menu")),
    (require("weread.ui.cache")),
    (require("weread.ui.read_report")),
    (require("weread.ui.library")),
    (require("weread.ui.shelf_progress")),
    (require("weread.ui.profile")),
    (require("weread.ui.home_settings")),
    (require("weread.ui.discovery")),
    (require("weread.ui.annotations_controller")),
    (require("weread.ui.xpointer_overlay_controller")),
    (require("weread.ui.annotation_sync_controller")),
    (require("weread.ui.reader_navigation")),
    (require("weread.ui.source_position")),
    (require("weread.lib.reader_lifecycle")),
})

return WeReadPlugin
