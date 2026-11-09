-- Bookshelf, book, chapter, public-account, and search UI flows.
local BookReviews = require("weread.lib.book_reviews")
local BookReviewsView = require("weread.ui.book_reviews_view")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weread.lib.content")
local ShelfGroups = require("weread.lib.shelf_groups")
local ShelfFlags = require("weread.lib.shelf_flags")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("weread.lib.logger")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists

local M = {}
local sortBooks

local function cover_subprocess_runner()
    local ok, ffiutil = pcall(require, "ffi/util")
    if not ok or type(ffiutil.runInSubProcess) ~= "function" then return nil end
    return {
        run = function(callback) return ffiutil.runInSubProcess(callback, true) end,
        write_all = function(fd, data) return ffiutil.writeToFD(fd, data, true) end,
        is_done = function(pid) return ffiutil.isSubProcessDone(pid) end,
        terminate = function(pid) return ffiutil.terminateSubProcess(pid) end,
        read_all = function(fd) return ffiutil.readAllFromFD(fd) end,
    }
end

local function terminate_cover_job(job)
    if job.termination_requested then return end
    job.termination_requested = true
    local ok = pcall(job.runner.terminate, job.pid)
    if not ok then
        job.termination_requested = nil
        logger.warn("bookshelf cover worker termination failed")
    end
end

local local_cache_fields = {
    cache_dir = true,
    cached_file = true,
    cached_full_book = true,
    cached_chapters = true,
}

local function keep_local_cache(record)
    local local_record = {}
    for key, value in pairs(record or {}) do
        if local_cache_fields[key] then local_record[key] = value end
    end
    return local_record
end

local function has_book_details(book)
    if type(book) ~= "table" then return false end
    if tonumber(book.detail_updated_at or 0) > 0 then return true end
    for _, key in ipairs({
        "intro", "publisher", "isbn", "wordCount", "newRating",
        "translator", "categoryName", "publishTime",
    }) do
        if book[key] ~= nil and book[key] ~= "" then return true end
    end
    return false
end

local function list_items_per_page()
    local perpage = 14
    if G_reader_settings and G_reader_settings.readSetting then
        perpage = tonumber(G_reader_settings:readSetting("items_per_page")) or perpage
    end
    return math.max(4, perpage)
end

function M:showBookshelf()
    if self._profile_view then self:closeWeReadUI() end
    local cached = self.library_db and self.library_db:getShelf() or nil
    local archives = self.library_db and self.library_db:getShelfArchives() or nil
    if cached and (#cached > 0 or archives ~= nil) then
        self:applyShelfSnapshot(cached, archives)
        self:showShelfView("books")
        local shelf = self.settings:get("shelf")
        -- Only old caches lack archive metadata; an empty archive is current.
        if archives == nil and not shelf.groups_refresh_hint_shown then
            local view = self.shelf_view
            local hint = ConfirmBox:new{
                text = _("Get the latest bookshelf to show your WeRead book groups.\n\nYou can also do this later with the refresh button in the top bar."),
                ok_text = _("Get latest"), cancel_text = _("Later"),
                ok_callback = function()
                    UIManager:nextTick(function()
                        if self.shelf_view == view then view.on_refresh() end
                    end)
                end,
            }
            hint.movable[1].radius = 0
            UIManager:show(hint)
            shelf.groups_refresh_hint_shown = true
            self.settings:set("shelf", shelf)
            self.settings:flush()
        end
        return
    end
    self:refreshBookshelf()
end

function M:closeWeReadUI()
    self:cancelShelfCovers()
    if self.cancelMPDownloadRecovery then self:cancelMPDownloadRecovery() end
    if self.cancelMPArticleCleanup then self:cancelMPArticleCleanup() end
    if self.cancelWebRenewal then self:cancelWebRenewal() end
    if self.cancelMPArticleCatalog then self:cancelMPArticleCatalog() end
    if self.cancelMPArticleDownload then self:cancelMPArticleDownload() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelMPArticleActions then self:cancelMPArticleActions() end
    if self.cancelShelfState then self:cancelShelfState() end
    if self.cancelReadingLanguage then self:cancelReadingLanguage() end
    if self.cancelLocalNotesExport then self:cancelLocalNotesExport() end
    if self.closeReaderLinkUI then self:closeReaderLinkUI() end
    if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
    if self.cancelShelfRefresh then self:cancelShelfRefresh() end
    if self.cancelDiscoveryRequest then self:cancelDiscoveryRequest() end
    if self.cancelBookMetadata then self:cancelBookMetadata() end
    if self.cancelBookReading then self:cancelBookReading() end
    if self.cancelReadStatsRequest then self:cancelReadStatsRequest() end
    if self.stopHomeStatusTimer then self:stopHomeStatusTimer() end
    if self.closeHomeControls then self:closeHomeControls(false) end
    self._home_pending_redraw = nil
    if self._stats_busy_generation then
        self._stats_busy_generation = nil
        self:closeBusy()
    end
    if self.cancelShelfProgress then self:cancelShelfProgress() end
    if self.cancelProfileRefresh then self:cancelProfileRefresh() end
    self.discovery_epoch = (self.discovery_epoch or 0) + 1
    -- Close from the topmost view down so no full-screen WeRead widget remains
    -- in UIManager's window stack after a document is opened.
    local seen = {}
    for _, field in ipairs({
        "_discovery_menu",
        "_mp_article_list_view",
        "_home_controls_menu",
        "_home_prefetch_confirmation",
        "_profile_goal_dialog",
        "_read_stats_view",
        "_profile_view",
        "_chapter_list_view",
        "_book_detail_view",
        "shelf_view",
    }) do
        local view = self[field]
        self[field] = nil
        if view and not seen[view] then
            seen[view] = true
            UIManager:close(view)
        end
    end
end

function M:onWeReadAccountChanged()
    if self.source_navigation then self.source_navigation:cancel() end
    if self.source_position then self.source_position:on_account_changed() end
    if self.native_renewal then self.native_renewal:cancel() end
    if self.native_authorization then self.native_authorization:cancel() end
    if self.offline_time then self.offline_time:stop("account_unavailable") end
    if self.read_report then self.read_report:stop("account_changed") end
    if self.progress_sync and self.progress_sync.on_account_changed then self.progress_sync:on_account_changed() end
    self:closeWeReadUI()
    self.discovery_state = nil
    self.discovery_categories = nil
    self.shelf_progress_retry_at = nil
    self.shelf_regular = nil
    self.shelf_mp = nil
    self.shelf_books = nil
    self.shelf_groups = nil
    self.shelf_group_key = nil
    self.shelf_search_keyword = nil
    self.shelf_view_pages = nil
    if self.offline_time then self.offline_time:resume() end
end

function M:applyShelfSnapshot(all_books, archives)
    local shelf = self.settings:get("shelf")
    self.shelf_filters = { reading = shelf.filter_reading, download = shelf.filter_download }
    self.shelf_regular = {}
    self.shelf_mp = {}
    for _i, book in ipairs(all_books or {}) do
        if WeRead.is_mp_book(book.book_id or book.bookId) then
            table.insert(self.shelf_mp, book)
        else
            table.insert(self.shelf_regular, book)
        end
    end
    self.shelf_books = self.shelf_regular
    self.shelf_groups = ShelfGroups.list(archives, self.shelf_regular, _("Unnamed group"), _("Uncategorized"))
    if self.shelf_group_key and not ShelfGroups.find(self.shelf_groups, self.shelf_group_key) then
        self.shelf_group_key = nil
        if self.shelf_view_pages then self.shelf_view_pages.books = 1 end
    end
end

function M:requireShelfLogin()
    if self.client.shelf_authentication then
        local ready, reason = self.client:shelf_authentication()
        if ready then return true end
        if reason == "native_required" and self.native_authorization then
            self.native_authorization:showMenu()
            return false
        end
        if reason == "login_required" then
            self:showTransientInfo(_("Please scan the QR code to log in first."), 2)
            UIManager:scheduleIn(0.2, function() self.qr_login:start() end)
            return false
        end
    end
    return self:requireLogin(false, true)
end

function M:cancelShelfRefresh()
    local context = self.shelf_refresh_context
    if not context then return end
    context.cancelled = true
    self.shelf_refresh_context, self.shelf_refreshing = nil, nil
    if self.shelf_refresh_worker then self.shelf_refresh_worker:cancel() end
    if context.renewal_job and self.native_renewal then self.native_renewal:cancel(context.renewal_job) end
    if context.old_view then pcall(context.old_view.setRefreshing, context.old_view, false) end
    if self.busy_message == context.busy then self:closeBusy() end
end

function M:refreshBookshelf(old_view, view_options)
    if self.shelf_refreshing or not self:requireShelfLogin() then return end
    self.shelf_refreshing = true
    local context = { old_view = old_view }
    self.shelf_refresh_context = context
    local refresh_epoch = self.discovery_epoch or 0
    local account_key = self.library_db and self.library_db.accountKey and self.library_db:accountKey()
    local scope = self.settings.get_auth_scope and self.settings:get_auth_scope()
    local source = require("weread.lib.shelf_source").mode(self.settings)
    if self.native_renewal then
        context.native_revision = require("weread.lib.shelf_source").selection(self.settings).revision
    end
    local function still_current()
        return not context.cancelled and (self.discovery_epoch or 0) == refresh_epoch
            and (not account_key or self.library_db:accountKey() == account_key)
            and (not scope or self.settings:auth_scope_matches(scope))
            and require("weread.lib.shelf_source").mode(self.settings) == source
    end
    -- A finishing thumbnail batch must not replace the view being refreshed.
    self:cancelShelfCovers()
    if old_view then old_view:setRefreshing(true) end
    local function done()
        if self.shelf_refresh_context ~= context then return end
        self.shelf_refresh_context, self.shelf_refreshing = nil, nil
        if old_view and still_current() then old_view:setRefreshing(false) end
        if self.busy_message == context.busy then self:closeBusy() end
    end
    self:showBusy(_("Loading bookshelf..."), function() self:cancelShelfRefresh() end)
    context.busy = self.busy_message
    local launch
    local function complete(ok, result)
        if not still_current() then done() return end
        if not ok and result == "shelf_source/native_expired" and self.native_renewal and not context.recovery_attempted then
            context.recovery_attempted = true
            local function renewed(success)
                if self.shelf_refresh_context ~= context or not still_current() then done() return end
                if success then launch(false, false)
                elseif source == "auto" then launch(false, true)
                else complete(false, "shelf_source/native_unavailable") end
            end
            local renewing, job = self.native_renewal:start({ expected_revision = context.native_revision }, renewed)
            if renewing then context.renewal_job = job else renewed(false) end
            return
        end
        done()
        if not still_current() then return end
        if ok and type(result) == "table" and result._native_revision ~= nil then
            local selected = require("weread.lib.shelf_source").selection(self.settings)
            if not selected.credentials or selected.revision ~= result._native_revision then return end
        end
        if ok and type(result) == "table" and result._web_revision ~= nil
            and require("weread.lib.shelf_source").web_revision(self.settings) ~= result._web_revision then return end
        if not ok then
            logger.err("load bookshelf failed:", log_error(result))
            if result == "shelf_source/native_unavailable" or result == "shelf_source/native_required" then
                self:showInfo(_("E-Ink bookshelf could not be read. Authorize again, or choose Automatic or Standard bookshelf."))
                return
            end
            if type(result) == "string" and result:match("^shelf_source/") then
                result = _("Bookshelf is unavailable. Check the network and authorization, then try again.")
            end
            self:showInfo(T(
                _("Load bookshelf failed:\n%1\n\nIf other account features still work, use Search to find and download books."),
                display_error(result)
            ))
            return
        end
        local all_books = type(result) == "table"
            and type(result.books) == "table"
            and result.books
            or {}
        local archives = type(result) == "table" and type(result.archive) == "table" and result.archive or {}
        local snapshot_saved=self.library_db and self.library_db:cacheShelf(all_books, archives)==true
        self.shelf_active_source = type(result) == "table" and result._shelf_source or "gateway"
        if type(result) == "table" and result._native_fallback then
            self:showTransientInfo(_("E-Ink bookshelf is unavailable. Using the standard bookshelf for this refresh."), 3)
        elseif type(result) == "table" and result._gateway_fallback then
            self:showTransientInfo(_("The standard connection is unavailable. Using the Web bookshelf for this refresh."), 3)
        end
        local old_group_key = self.shelf_group_key
        self:applyShelfSnapshot(all_books, archives)
        if view_options and view_options.on_loaded then
            view_options.on_loaded(snapshot_saved)
            return
        end
        local next_options = {}
        for key, value in pairs(view_options or {}) do next_options[key] = value end
        next_options.prepared_shelf = nil
        next_options.refresh_progress = true
        if old_group_key ~= self.shelf_group_key then
            next_options.page, next_options.scroll_offset = 1, nil
        end
        if old_view then UIManager:close(old_view) end
        self:showShelfView(
            view_options and view_options.mode or self.shelf_view_mode or "books",
            view_options and view_options.keyword or nil,
            nil,
            next_options
        )
    end
    local started
    if self.client.shelf_authentication then
        if not self:isNetworkConnected() then
            done()
            self:showOffline(_("Bookshelf"))
            return
        end
        if not self.shelf_refresh_worker then
            self.shelf_refresh_worker = require("weread.lib.memory_worker"):new{
                scheduler = UIManager, codec = self.client, max_bytes = 8 * 1024 * 1024,
            }
        end
        launch = function(recover_auth, skip_native)
            local ok = self.shelf_refresh_worker:start(function()
                if not still_current() then return { ok = false, error = "shelf_source/session_changed" } end
                local fetched, value = pcall(self.client.get_shelf, self.client,
                    { is_current = still_current, recover_auth = recover_auth, skip_native = skip_native })
                if fetched then return { ok = true, value = value } end
                return { ok = false, error = type(value) == "string" and value:match("^shelf_source/[a-z_]+$")
                    or "shelf_source/unavailable" }
            end, function(result)
                if self.shelf_refresh_context ~= context then return end
                complete(type(result) == "table" and result.ok == true, type(result) == "table" and (result.value or result.error)
                    or _("Bookshelf refresh was interrupted. Please try again."))
            end)
            if not ok then complete(false, "shelf_source/unavailable") end
            return ok
        end
        started = launch(self.native_renewal ~= nil, false)
    else
        started = self:runOnlineTask(_("Bookshelf"), function()
            if not still_current() then done() return end
            local ok, result = pcall(self.client.get_shelf, self.client)
            complete(ok, result)
        end)
    end
    if started == false then
        done()
        if self.client.shelf_authentication then self:showInfo(_("Could not start bookshelf refresh. Please try again.")) end
    end
end

local function shelf_search_match(book, keyword)
    if not keyword or keyword == "" then return true end
    local needle = string.lower(keyword)
    for _, value in ipairs({ book.title, book.author, book.bookId, book.book_id }) do
        if type(value) == "string" and string.find(string.lower(value), needle, 1, true) then
            return true
        end
    end
    return false
end

local function shelf_page_items(items, page, page_size)
    items = type(items) == "table" and items or {}
    page_size = math.max(1, math.floor(tonumber(page_size) or 1))
    local page_count = math.max(1, math.ceil(#items / page_size))
    page = math.max(1, math.min(math.floor(tonumber(page) or 1), page_count))
    local first = (page - 1) * page_size + 1
    local last = math.min(#items, first + page_size - 1)
    local result = {}
    for index = first, last do result[#result + 1] = items[index] end
    return result, page
end

-- Regular books already provide HTTPS covers. Public-account avatars are
-- commonly returned as http://wx.qlogo.cn URLs; use the equivalent HTTPS URL
-- so cover mode never requests an avatar over plaintext transport.
local function shelf_cover_url(book)
    local cover = type(book) == "table" and book.cover or nil
    if type(cover) ~= "string" then return nil end
    if cover:match("^https://") then return cover end
    if cover:match("^http://wx%.qlogo%.cn/") then
        return "https://" .. cover:sub(#"http://" + 1)
    end
    return nil
end

function M:getShelfCoverCache()
    if not self.shelf_cover_cache then
        local CoverCache = require("weread.lib.cover_cache")
        self.shelf_cover_cache = CoverCache:new(self.settings)
    end
    return self.shelf_cover_cache
end

function M:cancelShelfCovers(resume_on_wake)
    local job = self.shelf_cover_job
    local request = self.shelf_cover_pending or (job and job.request)
    self.shelf_cover_resume = resume_on_wake and request
        and request.view == self.shelf_view and request or nil
    self.shelf_cover_generation = (self.shelf_cover_generation or 0) + 1
    self.shelf_cover_pending = nil
    if job then
        job.cancelled = true
        terminate_cover_job(job)
    end
    -- Keep the job and its pipe until the existing poll has reaped the child.
    -- Reopened pages may queue work but cannot overlap a retiring writer.
end

function M:resumeShelfCovers()
    local request = self.shelf_cover_resume
    self.shelf_cover_resume = nil
    if request and request.view == self.shelf_view then
        self:fetchVisibleShelfCovers(request.view, request.items, request.options)
    end
end

function M:fetchVisibleShelfCovers(view, items, options)
    if not view or not items or #items == 0 then return end
    options = options or {}
    local cache = self:getShelfCoverCache()
    local visible = shelf_page_items(items, view.page, view.page_size or 6)
    local missing = {}
    local online = self:isNetworkOnline()
    for _, book in ipairs(visible) do
        if shelf_cover_url(book)
            and not cache:pathFor(book) then
            -- Legacy full-resolution cache entries can be converted while
            -- offline. A network request is only needed when no source exists.
            if online or cache:sourcePathFor(book) then
                missing[#missing + 1] = book
            end
        end
    end
    if #missing == 0 then return end

    if self.shelf_cover_job then
        -- Keep only the newest visible page while the current child exits.
        self.shelf_cover_pending = { view = view, items = items, options = options }
        if self.shelf_cover_job.request.view ~= view then
            self.shelf_cover_job.cancelled = true
            terminate_cover_job(self.shelf_cover_job)
        end
        return
    end

    local runner = self.shelf_cover_subprocess
    if runner == nil then
        runner = cover_subprocess_runner() or false
        self.shelf_cover_subprocess = runner
    end
    if not runner then
        logger.warn("bookshelf cover background worker is unavailable")
        return
    end

    local generation = self.shelf_cover_generation
    local index, changed = 1, false
    local function finish_batch()
        self.shelf_cover_job = nil
        if changed and generation == self.shelf_cover_generation and self.shelf_view == view then
            local pruned = pcall(cache.prune, cache)
            if not pruned then logger.warn("bookshelf cover cache pruning failed") end
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = {
                books = options.prepared_books or self.shelf_regular or {},
                accounts = options.prepared_accounts or self.shelf_mp or {},
            }
            next_options.page = view.page
            next_options.skip_cover_fetch_once = true
            if options.on_redraw then
                options.on_redraw(view.page)
            else
                self:showShelfView(options.mode or "books", options.keyword, view, next_options)
            end
        end
        local pending = self.shelf_cover_pending
        self.shelf_cover_pending = nil
        if pending then
            self:fetchVisibleShelfCovers(pending.view, pending.items, pending.options)
        end
    end

    local function fetch_next()
        if generation ~= self.shelf_cover_generation or self.shelf_view ~= view then
            finish_batch()
            return
        end
        local book = missing[index]
        if not book then
            finish_batch()
            return
        end

        local pid, read_fd = runner.run(function(_pid, child_write_fd)
            local ok, path = pcall(cache.thumbnailFromCached, cache, book)
            if not (ok and path) and online then
                local downloaded, data = pcall(function()
                    return self.client:get_binary(shelf_cover_url(book), {
                        skip_cookie = true,
                        persist_response_cookies = false,
                        sensitive = true,
                        diagnostic_api = "shelf_cover",
                        max_bytes = cache.MAX_IMAGE_BYTES,
                        timeout = { 8, 12 },
                    })
                end)
                if downloaded then ok, path = pcall(cache.store, cache, book, data) end
            end
            runner.write_all(child_write_fd, ok and path and "ok" or "error")
        end)
        if not pid then
            logger.warn("bookshelf cover background worker failed to start")
            index = index + 1
            UIManager:scheduleIn(0.1, fetch_next)
            return
        end

        local job = { pid = pid, read_fd = read_fd, started_at = os.time(), runner = runner,
            request = { view = view, items = items, options = options } }
        self.shelf_cover_job = job
        local poll
        poll = function()
            if self.shelf_cover_job ~= job then return end
            if not runner.is_done(job.pid) then
                if job.cancelled or os.time() - job.started_at > 30 then
                    -- A signal can race with the child's process-group setup.
                    -- Retry only while this exact child is still unreaped.
                    job.termination_requested = nil
                    terminate_cover_job(job)
                end
                UIManager:scheduleIn(0.15, poll)
                return
            end
            local result = job.read_fd and runner.read_all(job.read_fd) or nil
            job.read_fd = nil
            self.shelf_cover_job = nil
            -- Cancellation may race with a completed cache commit. Keep valid
            -- thumbnails, but never redraw or continue the cancelled page.
            if not job.cancelled then
                if result == "ok" and cache:pathFor(book) then
                    changed = true
                else
                    logger.warn("bookshelf cover background task failed")
                end
            end
            index = index + 1
            fetch_next()
        end
        UIManager:scheduleIn(0.15, poll)
    end
    fetch_next()
end


function M:showShelfView(mode, keyword, old_view, options)
    if self.stopHomeStatusTimer then self:stopHomeStatusTimer() end
    local LibraryView = require("weread.ui.library_view")
    options = options or {}
    mode = mode or "books"
    options.mode = mode
    options.keyword = keyword
    local skip_cover_fetch_once = options.skip_cover_fetch_once == true
    options.skip_cover_fetch_once = nil
    self:cancelShelfCovers()
    self.shelf_view_mode = mode
    self.shelf_search_keyword = keyword
    self.shelf_view_pages = self.shelf_view_pages or { books = 1, public_account = 1 }
    local saved_books = self.settings:get("books", {})
    local downloaded_cache = {}
    local function filtered(source, with_download_state)
        local result = {}
        local sorted = sortBooks(source or {}, self.settings:get("shelf").sort_order)
        for _i, book in ipairs(sorted) do
            local matches_filters = not with_download_state
                or self:bookMatchesFilters(book, saved_books, downloaded_cache)
            if matches_filters and shelf_search_match(book, keyword) then
                if with_download_state then
                    book._cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                end
                result[#result + 1] = book
            end
        end
        return result
    end
    local group = ShelfGroups.find(self.shelf_groups, self.shelf_group_key)
    local prepared = options.prepared_shelf
    local books = prepared and prepared.books or filtered(group and group.books or self.shelf_regular, true)
    local accounts = prepared and prepared.accounts or filtered(self.shelf_mp, false)
    local shelf_settings = self.settings:get("shelf")
    local cover_mode = shelf_settings.view_mode == "cover"
    local paged = cover_mode or shelf_settings.paginated ~= false
    local page = paged and (options.page or self.shelf_view_pages[mode] or 1) or 1
    local source = mode == "public_account" and accounts or books
    local navigation = self.discoveryNavigation and not options.on_select
        and self:discoveryNavigation("shelf") or nil
    local layout = LibraryView.getLayout(cover_mode, #source, mode, navigation and 54 or 0)
    local cover_layout = cover_mode and layout or nil
    local page_size = layout.page_size
    local progress_books, progress_snapshots
    if mode == "books" and self.prepareShelfProgress then
        progress_books = paged and shelf_page_items(source, page, page_size) or source
        progress_snapshots = self:prepareShelfProgress(progress_books)
    end
    local cover_paths, cover_loading
    if cover_mode then
        cover_paths = {}
        cover_loading = {}
        local cache = self:getShelfCoverCache()
        local online = self:isNetworkOnline()
        local visible, clamped_page = shelf_page_items(source, page, page_size)
        page = clamped_page
        for _, book in ipairs(visible) do
            local path = cache:pathFor(book)
            cover_paths[book] = path
            if not path and shelf_cover_url(book) then
                cover_loading[book] = online or cache:sourcePathFor(book) ~= nil
            end
        end
    end
    if old_view then UIManager:close(old_view) end
    local view, update_progress
    view = LibraryView.show({
        mode = mode,
        navigation = navigation,
        title = options.title,
        wp_enable = options.wp_enable,
        books = books,
        accounts = accounts,
        groups = self.shelf_groups,
        group_key = self.shelf_group_key,
        group_label = group and group.label,
        total_books = #(self.shelf_regular or {}),
        scroll_offset = options.scroll_offset,
        keyword = keyword,
        sort_label = self:shelfSortSummary(),
        filter_label = self:shelfFilterSummary(),
        paged = paged,
        page = page,
        page_size = page_size,
        cover_mode = cover_mode,
        cover_columns = cover_layout and cover_layout.columns,
        cover_rows = cover_layout and cover_layout.rows,
        cover_cell_height = cover_layout and cover_layout.cell_height,
        cover_paths = cover_paths,
        cover_loading = cover_loading,
    }, {
        on_visible_changed = function()
            if self.shelf_view == view and update_progress then update_progress() end
        end,
        on_close = function()
            if self.shelf_view == view then
                self.shelf_view = nil
                self:closeWeReadUI()
            end
        end,
        on_switch = function(new_mode)
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = { books = books, accounts = accounts }
            next_options.page = self.shelf_view_pages[new_mode] or 1
            next_options.scroll_offset = nil
            self:showShelfView(new_mode, keyword, view, next_options)
        end,
        on_select_group = function(key)
            if key and not ShelfGroups.find(self.shelf_groups, key) then return end
            self.shelf_group_key = key
            local next_options = {}
            for name, value in pairs(options) do next_options[name] = value end
            next_options.prepared_shelf, next_options.scroll_offset = nil, nil
            next_options.page = 1
            self:showShelfView("books", keyword, view, next_options)
        end,
        on_display_change = function(key, value)
            local shelf = self.settings:get("shelf")
            shelf[key] = value
            self.settings:set("shelf", shelf)
            self.settings:flush()
            options.page, options.scroll_offset = 1, nil
            self:showShelfView(mode, keyword, view, options)
        end,
        on_search = function()
            self:showShelfSearchDialog(view, mode, keyword, options)
        end,
        on_refresh = function()
            local refresh_options = {}
            for key, value in pairs(options) do refresh_options[key] = value end
            refresh_options.prepared_shelf = nil
            refresh_options.page = view.page
            refresh_options.scroll_offset = view:getScrollOffset()
            self:refreshBookshelf(view, refresh_options)
        end,
        on_sort = function()
            self:showShelfSortOptions(function()
                self.shelf_view_pages = { books = 1, public_account = 1 }
                options.prepared_shelf = nil
                options.page, options.scroll_offset = 1, nil
                self:showShelfView(mode, keyword, view, options)
            end)
        end,
        on_filter = function()
            self:showShelfFilterOptions(function()
                self.shelf_view_pages = { books = 1, public_account = 1 }
                options.prepared_shelf = nil
                options.page, options.scroll_offset = 1, nil
                self:showShelfView(mode, keyword, view, options)
            end)
        end,
        on_select = function(book, selected_mode)
            if options.on_select then
                options.on_select(book, selected_mode, view)
            elseif selected_mode == "public_account" then
                self:showMPAccount(book)
            else
                self:showBookRecord(book)
            end
        end,
        on_page_changed = function(new_page)
            self.shelf_view_pages[mode] = new_page
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = { books = books, accounts = accounts }
            next_options.page = new_page
            self:showShelfView(mode, keyword, view, next_options)
        end,
    })
    if paged then self.shelf_view_pages[mode] = view.page end
    self.shelf_view = view
    if progress_books then
        local force = options.refresh_progress
        options.refresh_progress = nil
        update_progress = function(refresh)
            self:refreshVisibleShelfProgress(view, paged and progress_books or view:getVisibleBooks(), progress_snapshots, {
                force = refresh,
                on_redraw = function()
                    local next_options = {}
                    for key, value in pairs(options) do next_options[key] = value end
                    next_options.prepared_shelf = { books = books, accounts = accounts }
                    next_options.page = self.shelf_view and self.shelf_view.page or page
                    next_options.scroll_offset = self.shelf_view and self.shelf_view:getScrollOffset()
                    self:showShelfView(mode, keyword, self.shelf_view, next_options)
                end,
            })
        end
        update_progress(force)
    elseif self.cancelShelfProgress then self:cancelShelfProgress() end
    if cover_mode and not skip_cover_fetch_once then
        local fetch_options = {}
        for key, value in pairs(options) do fetch_options[key] = value end
        fetch_options.prepared_books = books
        fetch_options.prepared_accounts = accounts
        self:fetchVisibleShelfCovers(view, source, fetch_options)
    end
end

function M:showShelfSearchDialog(view, mode, keyword, options)
    local dialog
    dialog = InputDialog:new{
        title = _("Search shelf"),
        input = keyword or "",
        input_type = "text",
        buttons = {{
            {
                text = _("Clear"),
                callback = self:safeCallback(_("Clear"), function()
                    UIManager:close(dialog)
                    self.shelf_view_pages = { books = 1, public_account = 1 }
                    options.prepared_shelf = nil
                    options.page, options.scroll_offset = 1, nil
                    self:showShelfView(mode, nil, view, options)
                end),
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = self:safeCallback(_("Search"), function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    self.shelf_view_pages = { books = 1, public_account = 1 }
                    options.prepared_shelf = nil
                    options.page = 1
                    self:showShelfView(
                        mode, value ~= "" and value or nil, view, options
                    )
                end),
            },
        }},
    }
    self:showInputDialog(dialog)
end

sortBooks = function(books, sort_order)
    if sort_order == "default" or not sort_order then
        return ShelfFlags.pinned_first(books)
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return ShelfFlags.pinned_first(sorted)
end

function M:showShelfPage()
    local books = self.shelf_books or {}
    if #books == 0 then
        self:showInfo(_("Your WeRead shelf is empty."))
        return
    end
    local menu, buildItems
    local function refresh()
        menu:switchItemTable(nil, buildItems())
    end
    buildItems = function()
        local items = self:shelfToolbarItems(true, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        local saved_books = self.settings:get("books", {})
        local downloaded_cache = {}
        self._shelf_saved_books = saved_books
        for _i, book in ipairs(sorted) do
            if self:bookMatchesFilters(book, saved_books, downloaded_cache) then
                local book_id = book.book_id or book.bookId
                local is_cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                local right_text
                if ShelfFlags.display(book,'finished')==true then
                    right_text = _("Done")
                elseif book.readUpdateTime and book.readUpdateTime > 0 then
                    right_text = os.date("%Y-%m-%d", book.readUpdateTime)
                else
                    right_text = ""
                end
                local labels={}
                if ShelfFlags.display(book,'pinned')==true then labels[#labels+1]=_('Pinned') end
                if ShelfFlags.display(book,'private')==true then labels[#labels+1]=_('Private') end
                if right_text~='' then labels[#labels+1]=right_text end
                right_text=table.concat(labels,' · ')
                local function rightStatus(cached)
                    if cached then
                        return right_text ~= "" and "✓  " .. right_text or "✓"
                    end
                    return right_text
                end
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    mandatory = rightStatus(is_cached),
                    mandatory_func = function()
                        local current = self._shelf_saved_books and self._shelf_saved_books[book_id]
                        return rightStatus(self:bookRecordHasDownload(current))
                    end,
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        return items
    end
    menu = self:showList(_("WeRead Bookshelf"), buildItems(), _("Your WeRead shelf is empty."))
    self.shelf_menu = menu
    self._shelf_refresh = refresh
end

function M:refreshShelfCacheIndicators()
    self._shelf_saved_books = self.settings:get("books", {})
    if self.shelf_menu and self._shelf_refresh then
        local ok, err = pcall(self._shelf_refresh)
        if not ok then
            logger.warn("refresh shelf cache indicators failed:", log_error(err))
        end
    end
end

function M:showBookRecord(book, options)
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if WeRead.is_mp_book(book_id) then
        self:showMPAccount(book)
        return
    end
    if not book_id then return end

    local account_key = self.library_db and self.library_db:accountKey() or nil
    local saved = books[book_id] or {}
    if account_key and saved._library_account_key
        and saved._library_account_key ~= account_key then
        saved = keep_local_cache(saved)
    end
    local cached = self.library_db and self.library_db:getBook(book_id) or nil
    for key, value in pairs(cached or {}) do
        if saved[key] == nil then saved[key] = value end
    end
    for key, value in pairs(book) do
        if value ~= nil and key ~= "_cached" then saved[key] = value end
    end
    saved.book_id = book_id
    saved._library_account_key = account_key
    saved.updated_at = saved.updated_at or os.time()
    books[book_id] = saved
    self.settings:set("books", books)
    self.settings:flush()
    if self.library_db then self.library_db:putBook(saved) end
    if type(saved.chapters) ~= "table" and self.library_db then
        saved.chapters = self.library_db:getChapters(book_id)
    end
    if not has_book_details(cached) and not (options and options.verified_metadata) then
        self:refreshBookRecord(saved, nil, { automatic = true })
    else
        self:showBookMenu(saved)
    end
end

function M:refreshBookRecord(book, old_view, options)
    return require("weread.ui.book_metadata").refresh(self, book, old_view, options)
end

function M:cancelBookMetadata()
    return require("weread.ui.book_metadata").cancel(self)
end

function M:showBookMenu(book)
    local BookDetailView = require("weread.ui.book_detail_view")
    local book_id = book.book_id or book.bookId
    if type(book.chapters) ~= "table" then
        book.chapters = self.library_db and self.library_db:getChapters(book_id) or nil
        if type(book.chapters) ~= "table" then
            local legacy_catalog = Content.load_catalog_cache(self.client, self.settings, book)
            if legacy_catalog and self.library_db then
                self.library_db:putChapters(book_id, legacy_catalog)
            end
        end
    end
    local saved = self.settings:get("books", {})[book_id] or book
    local cached_path = self:getFullBookCachePath(saved)
    local is_full_cached = file_exists(cached_path)
    local has_cache = self:bookRecordHasDownload(saved)
    book.cached_full_book = is_full_cached and cached_path or nil
    local cached_chapter_count = 0
    for _uid, path in pairs(book.cached_chapters or {}) do
        if file_exists(path) then cached_chapter_count = cached_chapter_count + 1 end
    end
    local total_chapters = type(book.chapters) == "table" and #book.chapters or nil
    if is_full_cached and cached_chapter_count == 0 and total_chapters then
        cached_chapter_count = total_chapters
    end
    local chapter_status = total_chapters
        and T(_("Cached %1/%2 chapters"), tostring(cached_chapter_count), tostring(total_chapters))
        or T(_("%1 chapters cached"), tostring(cached_chapter_count))

    local author_parts = {}
    if book.author and book.author ~= "" then author_parts[#author_parts + 1] = book.author end
    if book.translator and book.translator ~= "" then
        author_parts[#author_parts + 1] = T(_("Translated by %1"), book.translator)
    end
    local statuses = {}
    if book.progress and book.progress > 0 then
        statuses[#statuses + 1] = T(_("Progress %1%"), tostring(book.progress))
    end
    statuses[#statuses + 1] = chapter_status

    local metadata = {}
    local function format_field(label, value)
        if value == nil or value == "" then return nil end
        return T(_("%1: %2"), tostring(label), tostring(value))
    end
    local function add_row(left_label, left_value, right_label, right_value)
        local left = format_field(left_label, left_value)
        local right = format_field(right_label, right_value)
        if left or right then metadata[#metadata + 1] = { left = left, right = right } end
    end
    local word_count
    if book.wordCount and book.wordCount > 0 then
        word_count = book.wordCount >= 10000
            and string.format("%.1f%s", book.wordCount / 10000, _("w words"))
            or tostring(book.wordCount)
    end
    local rating
    if book.newRating and book.newRating > 0 then
        local score = string.format("%.1f", book.newRating / 100)
        rating = T(_("%1 (%2 ratings)"), score, tostring(book.newRatingCount or 0))
    end
    add_row(_("Publisher"), book.publisher,
        _("Publication date"), BookReviews.format_date(book.publishTime))
    local category = format_field(_("Category"), book.categoryName)
    if category then metadata[#metadata + 1] = { text = category } end
    local words = format_field(_("Word count"), word_count)
    if words then metadata[#metadata + 1] = { text = words } end
    add_row("ISBN", book.isbn, _("Rating"), rating)

    local view
    local open_chapter_list = self:safeCallback(_("Chapter list"), function()
        self:showChapterList(book, function()
            local latest = self.settings:get("books", {})[book_id] or book
            if view then UIManager:close(view) end
            self:showBookMenu(latest)
        end)
    end)
    local review_action = {
        text = _("Recommended / Latest"),
        callback = self:safeCallback(_("Book reviews"), function()
            self:showBookReviews(book)
        end),
    }
    local actions = {}
    local shelf_state_action
    if self.showShelfState then
        local owner_account=self.library_db and self.library_db:accountKey()
        local owner_session=self._reader_session_gen
        shelf_state_action={text=_('Shelf status'),callback=self:safeCallback(_('Shelf status'),function()
            if self._book_detail_view==view and self.library_db:accountKey()==owner_account and self._reader_session_gen==owner_session then
                self:showShelfState(tostring(book_id))
            end
        end)}
    end
    if self.showSimilarBooks then
        actions[#actions + 1] = {
            text = _("Similar books"),
            callback = self:safeCallback(_("Similar books"), function() self:showSimilarBooks(book) end),
        }
    end
    if shelf_state_action then actions[#actions+1]=shelf_state_action end
    if has_cache then
        actions[#actions + 1] = {
            text = _("Clear book cache"),
            callback = self:safeCallback(_("Clear book cache"), function()
                self:confirmClearBookCache(book_id, book.title or book_id, function()
                    book.cached_file = nil
                    book.cached_full_book = nil
                    book.cached_chapters = nil
                    book.cache_dir = nil
                    if view then UIManager:close(view) end
                    self:showBookMenu(book)
                end)
            end),
        }
    end
    local updated = book.detail_updated_at
        and os.date("%Y-%m-%d %H:%M", book.detail_updated_at) or _("Never updated")
    local bottom_actions = {
        {
            text = _("⇩ Download full book"),
            callback = self:safeCallback(_("Download full book"), function()
                self:confirmDownloadAllChapters(book)
            end),
        },
        {
            text = _("☷ Chapter list"),
            callback = open_chapter_list,
        },
        {
            text = _("▤ Read"),
            callback = self:safeCallback(_("Read"), function()
                self:startBookReading(book, view)
            end),
        },
    }
    view = BookDetailView.show({
        title = book.title or _("Book details"),
        author_line = table.concat(author_parts, "  ·  "),
        status_line = table.concat(statuses, "  ·  "),
        refresh_label = _("↻ Get latest information"),
        refresh_date = updated,
        metadata = metadata,
        intro = book.intro,
        review_action = review_action,
        actions = actions,
        bottom_actions = bottom_actions,
    }, {
        on_refresh = self:safeCallback(_("Get latest information"), function()
            self:refreshBookRecord(book, view)
        end),
        on_close = function()
            if self._book_detail_view == view then
                if self.cancelShelfState then self:cancelShelfState() end
                self:cancelBookMetadata()
                self:cancelBookReading()
                if self.cancelDiscoveryRequest then self:cancelDiscoveryRequest() end
                self._book_detail_view = nil
                self.discovery_epoch = (self.discovery_epoch or 0) + 1
            end
        end,
    })
    self._book_detail_view = view
    return view
end

function M:showBookReviewDetail(book, review, mode)
    local author = review.author ~= "" and review.author or _("Anonymous")
    local metadata = {}
    if review.rating > 0 then
        metadata[#metadata + 1] = T(
            _("Score %1"), BookReviews.format_rating(review.rating)
        )
    end
    local review_date = BookReviews.format_date(review.create_time)
    if review_date ~= "" then
        metadata[#metadata + 1] = review_date
    end
    if review.is_finish then
        metadata[#metadata + 1] = _("Finished")
    end

    local text = {}
    text[#text + 1] = "《" .. tostring(book.title or _("Untitled")) .. "》"
    text[#text + 1] = author
    if #metadata > 0 then
        text[#text + 1] = table.concat(metadata, " · ")
    end
    text[#text + 1] = ""
    text[#text + 1] = review.content ~= "" and review.content or _("No review content.")

    UIManager:show(TextViewer:new{
        title = mode == "latest" and _("Latest review") or _("Recommended review"),
        text = table.concat(text, "\n"),
        text_type = "general",
        auto_para_direction = true,
    })
end

function M:showBookReviews(book)
    if not self:requireLogin(false, true) then
        return
    end
    local book_id = book.book_id or book.bookId
    local session = {
        cache = {},
    }

    local loadReviews
    loadReviews = function(mode, old_view)
        local function showResult(result)
            if old_view then
                UIManager:close(old_view)
            end
            local view
            view = BookReviewsView.show({
                book_title = book.title or _("Untitled"),
                mode = mode,
                result = result,
            }, {
                on_switch = function(new_mode)
                    loadReviews(new_mode, view)
                end,
                on_select = function(review, selected_mode)
                    self:showBookReviewDetail(book, review, selected_mode)
                end,
            })
        end

        if session.cache[mode] then
            showResult(session.cache[mode])
            return
        end
        self:showBusy(_("Loading book reviews..."))
        self:runOnlineTask(_("Book reviews"), function()
            local ok, result = pcall(function()
                local list_type = mode == "latest" and 3 or 1
                return BookReviews.normalize_list(
                    self.client:get_book_reviews(book_id, list_type, 20)
                )
            end)
            self:closeBusy()
            if not ok then
                logger.err("load book reviews failed:", log_error(result))
                self:showInfo(T(_("%1 failed:\n%2"), _("Book reviews"), display_error(result)))
                return
            end
            session.cache[mode] = result
            showResult(result)
        end)
    end

    loadReviews("recommended", nil)
end

function M:showShelfTabs()
    local items = {
        {
            text = _("Books"),
            post_text = T(_("%1 books"), tostring(#self.shelf_regular)),
            callback = self:safeCallback(_("Books"), function()
                self.shelf_books = self.shelf_regular
                self:showShelfPage()
            end),
        },
        {
            text = _("Public Accounts"),
            post_text = T(_("%1 accounts"), tostring(#self.shelf_mp)),
            callback = self:safeCallback(_("Public Accounts"), function()
                self:showMPShelfPage()
            end),
        },
    }
    self:showList(_("WeRead Bookshelf"), items, _("Your WeRead shelf is empty."))
end

function M:showMPShelfPage()
    local books = self.shelf_mp or {}
    if #books == 0 then
        self:showInfo(_("No items."))
        return
    end
    local menu, buildItems
    local function refresh() menu:switchItemTable(nil, buildItems()) end
    buildItems = function()
        local items = self:shelfToolbarItems(false, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        for _i, book in ipairs(sorted) do
            table.insert(items, {
                text = book.title or book.bookId or _("Untitled"),
                post_text = book.author or "",
                callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                    self:showMPAccount(book)
                end),
            })
        end
        return items
    end
    menu = self:showList(_("Public Accounts"), buildItems(), _("No items."))
end

function M:showMPAccount(book)
    self:rememberMPAccount(book)
    local book_id = book.book_id or book.bookId
    local cached = self:getCachedMPArticles(book_id)
    if type(cached)=='table' then
        self:showMPArticleList(book, cached)
        return
    end
    if not self:requireLogin(true, false) then return end
    self:fetchMPArticles(book)
end

function M:rememberMPAccount(book)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return
    end
    local books = self.settings:get("books", {})
    local record = books[book_id] or {}
    record.book_id = book_id
    record.title = book.title or record.title
    record.author = book.author or record.author
    record.updated_at = os.time()
    -- Keep the resolved cache directory in sync both ways so the transient book
    -- object used for cached-path lookups knows where its articles actually live.
    record.cache_dir = book.cache_dir or record.cache_dir
    book.cache_dir = record.cache_dir
    books[book_id] = record
    self.settings:set("books", books)
    self.settings:flush()
end

function M:fetchMPArticles(book)
    return require('weread.ui.mp_catalog').start(self,book)
end

function M:cancelMPArticleCatalog()
    return require('weread.ui.mp_catalog').cancel(self)
end

function M:getCachedMPArticles(book_id)
    local books = self.settings:get("books", {})
    local record = books[book_id]
    if record and record.mp_articles then
        return record.mp_articles
    end
    return nil
end

function M:cacheMPArticles(book_id, articles)
    local books = self.settings:get("books", {})
    books[book_id] = books[book_id] or {}
    books[book_id].mp_articles = articles
    books[book_id].mp_articles_time = os.time()
    self.settings:set("books", books)
    self.settings:flush()
end

function M:showMPArticleList(book, articles)
    if self.cancelWebRenewal then self:cancelWebRenewal() end
    if self.cancelMPArticleCatalog then self:cancelMPArticleCatalog() end
    local previous=self._mp_article_list_view;self._mp_article_list_view=nil
    if previous then UIManager:close(previous) end
    local owner_account=self.library_db and self.library_db:accountKey()
    local owner_epoch=self.discovery_epoch or 0
    local owner_document=self.ui and self.ui.document
    local owner_session=self._reader_session_gen
    local menu
    local function current()
        return self._mp_article_list_view==menu and owner_account==(self.library_db and self.library_db:accountKey())
            and owner_epoch==(self.discovery_epoch or 0) and owner_document==(self.ui and self.ui.document)
            and owner_session==self._reader_session_gen
    end
    local items = {}
    if #articles==0 then items[1]={text=_("No articles."),select_enabled=false} end
    for _i, article in ipairs(articles) do
        local title=type(article.title)=="string" and article.title~="" and article.title or _("Article")
        local cached_path,cache_reason = Content.mp_article_cached_path(self.settings, book, article)
        local is_cached = cached_path ~= nil
        local date_str = ""
        if article.createTime and article.createTime > 0 then
            date_str = os.date("%Y-%m-%d", article.createTime)
        end
        table.insert(items, {
            text = title,
            post_text = date_str,
            mandatory = is_cached and (cache_reason=='legacy' and _("Legacy cache") or _("Cached"))
                or cache_reason=='ambiguous_legacy' and _("Legacy cache needs refresh") or "",
            callback = self:safeCallback(title, function()
                if not current() then return end
                if is_cached then
                    require('weread.ui.mp_record_recovery').open(self,book,article,cached_path)
                else
                    self:downloadMPArticleAndRead(book, article)
                end
            end),
        })
    end
    if #articles==100 then items[#items+1]={text=_("First 100 articles loaded."),select_enabled=false} end
    table.insert(items, {
        text = _("Article cache and versions"),
        callback = self:safeCallback(_("Article cache and versions"), function()
            if current() then self:showMPArticleActions(book,articles) end
        end),
    })
    table.insert(items, {
        text = _("Repair interrupted downloads"),
        callback = self:safeCallback(_("Repair interrupted downloads"), function()
            if current() then require('weread.ui.mp_download_recovery').list(self,book,articles) end
        end),
    })
    table.insert(items, {
        text = _("Export cached article"),
        callback = self:safeCallback(_("Export cached article"), function()
            if not current() then return end
            self:showMPArticleExportList(book, articles)
        end),
    })
    table.insert(items, {
        text = _("Refresh article list"),
        callback = self:safeCallback(_("Refresh article list"), function()
            if not current() then return end
            self:fetchMPArticles(book)
        end),
    })
    menu=self:showList(book.title or _("Public Account"), items, _("No articles."));self._mp_article_list_view=menu
    if menu then
        local on_close=menu.onCloseWidget
        menu.onCloseWidget=function(instance,...)
            if self._mp_article_list_view==instance then self._mp_article_list_view=nil end
            if on_close then return on_close(instance,...) end
        end
    end
end

function M:downloadMPArticleAndRead(book, article)
    return require('weread.ui.mp_download').start(self,book,article)
end

function M:cancelMPArticleDownload()
    return require('weread.ui.mp_download').cancel(self)
end

function M:showMPArticleActions(book,articles)
    return require('weread.ui.mp_article_actions').list(self,book,articles)
end

function M:cancelMPArticleActions()
    return require('weread.ui.mp_article_actions').cancel(self)
end

function M:cancelMPArticleCleanup()
    return require('weread.ui.mp_cache_cleanup').cancel(self)
end

function M:cancelMPDownloadRecovery()
    return require('weread.ui.mp_download_recovery').cancel(self)
end

function M:loadChapters(book, callback, force_refresh)
    if not force_refresh then
        if book.chapters and #book.chapters > 0 then
            local book_id = book.book_id or book.bookId
            if self.library_db and book_id then
                self.library_db:putChapters(book_id, book.chapters)
            end
            local catalog_path = Content.catalog_cache_path(
                self.settings, book)
            if catalog_path and not file_exists(catalog_path) then
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, book.chapters)
                if not cache_ok then
                    logger.warn("save chapter catalog cache failed:",
                        log_error(cache_err))
                end
            end
            callback(book.chapters)
            return
        end
        local book_id = book.book_id or book.bookId
        local cached = self.library_db and self.library_db:getChapters(book_id) or nil
        if type(cached) == "table" and #cached > 0 then
            book.chapters = cached
            local catalog_path = Content.catalog_cache_path(
                self.settings, book)
            if catalog_path and not file_exists(catalog_path) then
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, cached)
                if not cache_ok then
                    logger.warn("save chapter catalog cache failed:",
                        log_error(cache_err))
                end
            end
        else
            cached = Content.load_catalog_cache(self.client, self.settings, book)
            if type(cached) == "table" and #cached > 0 and self.library_db then
                self.library_db:putChapters(book_id, cached)
            end
        end
        if type(cached) == "table" and #cached > 0 then
            callback(cached)
            return
        end
    end
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Loading chapter list..."), function()
        self:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            Content.ensure_reader_state(self.client, book)
            return Content.fetch_catalog(self.client, book)
        end)
        self:closeBusy()
        if not ok then
            logger.err("load chapters failed:", log_error(chapters_or_err))
            self:showInfo(T(_("Load chapters failed:\n%1"), display_error(chapters_or_err)))
            return
        end
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters_or_err)
        if not cache_ok then
            logger.warn("save chapter catalog cache failed:", log_error(cache_err))
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            if self.library_db then
                self.library_db:putChapters(book_id, chapters_or_err)
                self.library_db:putBook(book)
            end
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function M:showChapterList(book, on_close)
    local ChapterListView = require("weread.ui.chapter_list_view")
    local function reloadBookCache()
        if not self.settings then return end
        local book_id = book.book_id or book.bookId
        local latest = book_id and self.settings:get("books", {})[book_id]
        if type(latest) ~= "table" then return end
        for field in pairs(local_cache_fields) do
            if latest[field] ~= nil then book[field] = latest[field] end
        end
        if self.library_db then self.library_db:putBook(latest) end
    end
    local showCatalog
    showCatalog = function(chapters, old_view)
        -- Downloads persist their cache paths before invoking on_complete.
        -- Always rebuild from that persisted record instead of the snapshot
        -- captured when the chapter list was first opened.
        reloadBookCache()
        local rows = {}
        for _i, chapter in ipairs(chapters) do
            local chapter_uid = chapter.chapterUid or chapter.chapterId
            local cached = book.cached_chapters
                and book.cached_chapters[tostring(chapter_uid)]
            if cached and not file_exists(cached) then
                book.cached_chapters[tostring(chapter_uid)] = nil
                cached = nil
            end
            rows[#rows + 1] = {
                title = chapter.title or T(_("Chapter %1"), tostring(chapter_uid)),
                status = cached and _("Cached")
                    or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                source = chapter,
            }
        end
        if old_view then
            UIManager:close(old_view)
            if self._chapter_list_view == old_view then
                self._chapter_list_view = nil
            end
        end
        local view
        view = ChapterListView.show({
            title = book.title or _("Chapter list"),
            chapters = rows,
        }, {
            on_refresh = self:safeCallback(_("Refresh chapter list"), function()
                self:loadChapters(book, function(refreshed_chapters)
                    showCatalog(refreshed_chapters, view)
                    self:showTransientInfo(T(_("Chapter list refreshed: %1 chapters"),
                        tostring(#refreshed_chapters)), 2)
                end, true)
            end),
            on_select_download = self:safeCallback(_("Select chapters to download"), function()
                self:showChapterDownloadSelection(book, chapters, function()
                    showCatalog(chapters, view)
                end)
            end),
            on_select = function(chapter)
                self:openChapter(book, chapter, function()
                    -- The downloader has persisted the new chapter path before
                    -- this callback runs. Rebuild beneath the completion dialog
                    -- so either "Read now" or "Close" leaves current cache state.
                    UIManager:scheduleIn(0.1, function()
                        showCatalog(chapters, view)
                    end)
                end)
            end,
            on_close = function()
                if self._chapter_list_view == view then
                    self._chapter_list_view = nil
                end
                if on_close then on_close() end
            end,
        })
        self._chapter_list_view = view
    end
    self:loadChapters(book, function(chapters)
        showCatalog(chapters)
    end)
end

function M:showChapterDownloadSelection(book, chapters, on_downloaded)
    local selected = {}
    local menu
    local function selectedChapters()
        local result = {}
        for _i, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId or _i)
            if selected[uid] then
                result[#result + 1] = chapter
            end
        end
        return result
    end
    local function selectedCount()
        local count = 0
        for _uid in pairs(selected) do count = count + 1 end
        return count
    end

    local items = {}
    local perpage = list_items_per_page()
    local chapters_per_page = math.max(1, perpage - 1)
    local function appendDownloadAction()
        items[#items + 1] = {
            text_func = function()
                return T(_("[Download] Selected chapters (%1)"),
                    tostring(selectedCount()))
            end,
            bold = true,
            select_enabled_func = function() return selectedCount() > 0 end,
            separator = true,
            callback = self:safeCallback(_("Download selected chapters"), function()
                local targets = selectedChapters()
                if #targets == 0 then return end
                self:confirmAndDownloadChapters(book, targets, "chapters", {
                    separate_chapters = true,
                    on_complete = function(ok)
                        if not ok then return end
                        UIManager:scheduleIn(0.1, function()
                            if menu then UIManager:close(menu) end
                            if on_downloaded then on_downloaded() end
                        end)
                    end,
                })
            end),
        }
    end
    for page_start = 1, #chapters, chapters_per_page do
        appendDownloadAction()
        local page_end = math.min(#chapters, page_start + chapters_per_page - 1)
        for chapter_index = page_start, page_end do
            local chapter = chapters[chapter_index]
            local uid = tostring(chapter.chapterUid or chapter.chapterId or chapter_index)
            local cached = book.cached_chapters and book.cached_chapters[uid]
            local is_cached = file_exists(cached)
            items[#items + 1] = {
                text_func = function()
                    local marker = selected[uid] and "[✓] " or "[  ] "
                    return marker .. (chapter.title or T(_("Chapter %1"), uid))
                end,
                mandatory_func = function()
                    if selected[uid] then return _("Selected") end
                    return is_cached and _("Cached")
                        or T(_("%1 words"), tostring(chapter.wordCount or 0))
                end,
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if selected[uid] then
                        selected[uid] = nil
                    else
                        selected[uid] = true
                    end
                    if menu then menu:updateItems() end
                end),
            }
        end
    end
    menu = self:showList(_("Select chapters to download"), items,
        _("No chapters."), { items_per_page = perpage })
end

function M:openFile(path, after_open_callback)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    self:closeWeReadUI()
    if self.ui.document then
        self.ui:switchDocument(path, nil, after_open_callback)
    else
        self.ui:openFile(path, nil, nil, nil, after_open_callback)
    end
end

function M:openCachedBook(book)
    self:openFile(self:getFullBookCachePath(book))
end

-- Read offline from the best available cache. A complete EPUB wins. Otherwise
-- choose the cached chapter nearest to the last known chapter/progress, with a
-- slight preference for the preceding chapter when distances are equal.
function M:openBookForReading(book, quiet)
    local full_path = self:getFullBookCachePath(book)
    if file_exists(full_path) then
        self:openFile(full_path)
        return true
    end

    local book_id = book.book_id or book.bookId
    local chapters = book.chapters
    if type(chapters) ~= "table" and self.library_db then
        chapters = self.library_db:getChapters(book_id)
        if chapters then book.chapters = chapters end
    end
    if type(chapters) ~= "table" then
        chapters = Content.load_catalog_cache(self.client, self.settings, book)
    end

    local candidates = {}
    local target_index
    local account=self.library_db and self.library_db.accountKey and self.library_db:accountKey()
    if account==nil and self.progress_sync and self.progress_sync._account_key then account=self.progress_sync:_account_key() end
    local Reading=require('weread.ui.book_reading')
    if type(chapters) == "table" then
        target_index=Reading.resume_index(chapters,book,nil,account)
        for index, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId or index)
            local path = book.cached_chapters and book.cached_chapters[uid]
            if file_exists(path) then
                candidates[#candidates + 1] = { index = index, path = path }
            end
        end
        if not target_index and tonumber(book.progress) then
            local progress = math.max(0, math.min(100, tonumber(book.progress)))
            target_index = math.floor(progress / 100 * math.max(0, #chapters - 1)) + 1
        end
    end

    if #candidates > 0 then
        target_index = target_index or candidates[1].index
        table.sort(candidates, function(left, right)
            local left_distance = math.abs(left.index - target_index)
            local right_distance = math.abs(right.index - target_index)
            if left_distance ~= right_distance then return left_distance < right_distance end
            local left_precedes = left.index <= target_index
            local right_precedes = right.index <= target_index
            if left_precedes ~= right_precedes then return left_precedes end
            return left.index < right.index
        end)
        self:openFile(candidates[1].path)
        return true
    end

    local fallback_paths = {}
    for uid, path in pairs(book.cached_chapters or {}) do
        if file_exists(path) then fallback_paths[#fallback_paths + 1] = { uid = tostring(uid), chapterUid=tostring(uid), path = path } end
    end
    table.sort(fallback_paths, function(left, right) return left.uid < right.uid end)
    local fallback=fallback_paths[Reading.resume_index(fallback_paths,book,nil,account) or 1]
    if fallback then
        self:openFile(fallback.path)
        return true
    end
    if not quiet then self:showInfo(_("No cached file.")) end
    return false
end

function M:startBookReading(book, view)
    if view and self._book_detail_view ~= view then return false end
    local id = book.book_id or book.bookId
    local latest = self.settings:get_book(id) or book
    if self:openBookForReading(latest, true) then return true end
    return require("weread.ui.book_reading").start(self, latest, view)
end

function M:cancelBookReading()
    return require("weread.ui.book_reading").cancel(self)
end

-- Open a chapter, preferring its cached file and falling back to a download.
function M:openChapter(book, chapter, on_downloaded)
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
    elseif self.downloader:promotePrefetch(book, chapter) then
        -- The downloader promotes the background task to a visible progress
        -- dialog and opens the chapter as soon as the same task completes.
        return
    else
        self:downloadChapterAndRead(book, chapter, on_downloaded)
    end
end

-- Open a chapter selected by cloud-progress resolution. Unlike ordinary
-- chapter navigation, a missing target must be confirmed explicitly and then
-- opened automatically so ProgressSync can apply its pending in-chapter jump
-- in the next onReaderReady event.
function M:openProgressTargetChapter(book, chapter)
    if type(book) ~= "table" or type(chapter) ~= "table" then
        return false, "target_chapter_unavailable"
    end
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local sync = self.progress_sync
    local pending, scope = sync and sync.pending_jump, sync and sync:_scope()
    local function current()
        return sync and sync:chapter_request_current(pending, scope)
    end
    local function open_target(path)
        if not current() then return false end
        local handoff = sync:chapter_handoff(path)
        if not handoff then return false end
        self:openFile(path, handoff)
        return true
    end
    if not current() then return false, "target_chapter_unavailable" end
    local cached = chapter_uid and book.cached_chapters
        and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        return open_target(cached)
    end

    local title = chapter.title
        or T(_("Chapter %1"), tostring(chapter_uid or ""))
    local confirm
    confirm = ConfirmBox:new{
        text = T(_(
            "Cloud progress is in \"%1\", but this chapter has not been downloaded.\n\n"
            .. "Download and open it now?"
        ), title),
        ok_text = _("Download target chapter"),
        ok_callback = self:safeCallback(_("Download target chapter"), function()
            UIManager:close(confirm)
            if not current() then return end
            self.downloader:start(book, { chapter }, "chapter", {
                single_chapter = true,
                silent_completion = true,
                offer_read = false,
                on_complete = function(ok, reason)
                    if not current() then return end
                    if not ok then
                        sync:cancel_pending_jump(reason)
                    else
                        -- Both downloader paths finish their job after this
                        -- callback. Open once its cleanup has completed.
                        UIManager:scheduleIn(0.1, function() open_target(reason) end)
                    end
                end,
            })
        end),
        cancel_text = _("Cancel"),
        cancel_callback = function()
            if current() then
                sync:cancel_pending_jump(
                    "target_chapter_download_cancelled")
            end
        end,
    }
    UIManager:show(confirm)
    return true
end

function M:downloadChapterAndRead(book, chapter, on_downloaded)
    self:confirmAndDownloadChapters(book, { chapter }, "chapter", {
        single_chapter = true,
        on_complete = function(ok, path)
            if ok and on_downloaded then on_downloaded(path) end
        end,
    })
end

function M:confirmDownloadAllChapters(book)
    self:loadChapters(book, function(chapters)
        self:confirmAndDownloadChapters(book, chapters, "full", {
            confirmation_text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
        })
    end)
end

-- Annotation matching is a reading action, shared by all download forms.
function M:confirmAndDownloadChapters(book, chapters, suffix, options)
    options = options or {}
    local text = options.confirmation_text
        or T(_("Download %1 selected chapter(s)?"), tostring(#chapters))
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Download"), cancel_text = _("Cancel"),
        ok_callback = self:safeCallback(_("Download"), function()
            self.downloader:start(book, chapters, suffix, options)
        end),
    })
end

function M:pullProgressWithUI(book_id)
    if not self:requireLogin(true, true) then
        return
    end
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
    end)
end

function M:showSearch()
    if not self:requireLogin(true, true) then
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Search"), function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchWithUI(keyword)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function M:searchWithUI(keyword)
    if not keyword or keyword == "" then
        return
    end
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/store/search", {
                keyword = keyword,
                count = 10,
            })
        end)
        if not ok then
            logger.err("search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local items = {}
        for group_index, group in ipairs(result.results or {}) do
            for book_index, entry in ipairs(group.books or {}) do
                local book = entry.bookInfo or entry
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    mandatory = book.category or "",
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        self:showList(T(_("Search: %1"), keyword), items, _("No search results."))
    end)
end

function M:showImportedBooks()
    return require("weread.ui.reader_link").list(self,0)
end

function M:showPasteReaderURL()
    return require("weread.ui.reader_link").input(self)
end

function M:parseReaderURLWithUI(url)
    return require("weread.ui.reader_link").start(self,url)
end

function M:closeReaderLinkUI()
    return require("weread.ui.reader_link").close(self)
end

function M:cancelReaderLinkImport()
    return require("weread.ui.reader_link").cancel(self)
end

function M:showReadingLanguage()
    return require("weread.ui.translation").show(self)
end

function M:cancelReadingLanguage()
    return require("weread.ui.translation").cancel(self)
end

function M:onTranslationReadSettings()
    return require("weread.ui.translation").restore(self)
end

function M:onPreRenderDocument()
    return require("weread.ui.translation").pre_render(self)
end

function M:onTranslationReaderReady()
    return require("weread.ui.translation").reader_ready(self)
end

function M:closeReadingLanguageDocument()
    return require("weread.ui.translation").document_close(self)
end

function M:showLocalNotesExport()
    return require("weread.ui.notes_export").show(self)
end

function M:showMPArticleExport(book,article)
    return require('weread.ui.mp_export').show(self,book,article)
end

function M:showMPArticleExportList(book,articles)
    return require('weread.ui.mp_export').list(self,book,articles)
end

function M:showCurrentMPArticleExport()
    return require('weread.ui.mp_export').current(self)
end

function M:cancelMPArticleExport()
    return require('weread.ui.mp_export').cancel(self)
end

function M:showShelfState(book_id)
    return require('weread.ui.shelf_state').show(self,book_id)
end

function M:cancelShelfState()
    return require('weread.ui.shelf_state').cancel(self)
end

function M:cancelLocalNotesExport()
    return require("weread.ui.notes_export").cancel(self)
end


function M:showCurrentBookDetails()
    local book_id = self:detectWeReadBook()
    local book = book_id and self.settings:get("books", {})[book_id] or nil
    if not book then
        self:showInfo(_("The current document is not a WeRead cached book."))
        return
    end
    book.book_id = book.book_id or book_id
    self:showBookRecord(book)
end

return M
