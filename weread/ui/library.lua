-- Bookshelf, book, chapter, public-account, and search UI flows.
local BookReviews = require("weread.lib.book_reviews")
local BookStore = require("weread.lib.book_store")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weread.lib.content")
local ShelfGroups = require("weread.lib.shelf_groups")
local ShelfFlags = require("weread.lib.shelf_flags")
local ShelfSearch = require("weread.lib.shelf_search")
local ShelfProgress = require("weread.lib.shelf_progress")
local ShelfSnapshot = require("weread.lib.shelf_snapshot")
local ShelfTime = require("weread.lib.shelf_time")
local VolatileShelf = require("weread.lib.volatile_shelf")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("weread.lib.logger")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")
local ReadAccess = require("weread.lib.read_access")
local DiscoveryData = require("weread.lib.discovery_data")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists

local M = {}
local sortBooks
local GROUP_SELECTION_KEY = 'shelf_multi_groups_v1'
local LOCAL_GROUPS_KEY = 'shelf_local_groups_v1'
local group_owner

local function load_local_groups(host)
    local model=require('weread.lib.local_shelf_groups')
    local account=group_owner(host)
    local db=host.library_db
    if not account or not db or type(db.getProfileState)~='function' then
        host.shelf_local_state,host.shelf_local_original,host.shelf_local_owner=nil,nil,nil;return
    end
    local ok,state=pcall(db.getProfileState,db,LOCAL_GROUPS_KEY)
    if not ok or group_owner(host)~=account or state~=nil and not model.valid(state) then
        host.shelf_local_state,host.shelf_local_original,host.shelf_local_owner=nil,nil,nil;return
    end
    host.shelf_local_state,host.shelf_local_original,host.shelf_local_owner=state or model.empty(),state,account
end

local function load_local_pins(host)
    local model=require('weread.lib.local_shelf_pins')
    local account=group_owner(host);local db=host.library_db
    if not account or not db or type(db.getProfileState)~='function' then
        host.shelf_pins_state,host.shelf_pins_original,host.shelf_pins_owner=nil,nil,nil;return
    end
    local ok,state=pcall(db.getProfileState,db,model.KEY)
    if not ok or group_owner(host)~=account or state~=nil and not model.valid(state) then
        host.shelf_pins_state,host.shelf_pins_original,host.shelf_pins_owner=nil,nil,nil;return
    end
    host.shelf_pins_state,host.shelf_pins_original,host.shelf_pins_owner=state or model.empty(),state,account
end

group_owner=function(host)
    local db=host.library_db
    if not db or type(db.accountKey)~='function' then return nil end
    local ok,account=pcall(db.accountKey,db)
    return ok and type(account)=='string' and account~='' and account or nil
end

local function project_local_groups(host)
    local groups={};for _,group in ipairs(host.shelf_cloud_groups or {}) do groups[#groups+1]=group end
    if host.shelf_local_state and host.shelf_local_owner==group_owner(host) then
        local local_groups=require('weread.lib.local_shelf_groups').project(host.shelf_local_state,host.shelf_regular,
            function(label) return T(_('Local · %1'),label) end)
        for _,group in ipairs(local_groups or {}) do groups[#groups+1]=group end
    end
    host.shelf_groups=groups
end

local function load_group_selection(host)
    local account=group_owner(host)
    if host._shelf_multi_loaded and host._shelf_multi_owner==account then return end
    if host._shelf_multi_loaded and host._shelf_multi_owner~=account then host.shelf_group_key=nil end
    host._shelf_multi_loaded=true;host._shelf_multi_owner=account;host.shelf_multi_groups={}
    local db=host.library_db
    if account and type(db.getProfileState)=='function' then
        local ok,state=pcall(db.getProfileState,db,GROUP_SELECTION_KEY)
        if ok and group_owner(host)==account and type(state)=='table' then
            host.shelf_multi_groups=ShelfGroups.normalize(state.keys) or {}
        end
    end
end

local function save_group_selection(host,keys)
    keys=ShelfGroups.normalize(keys)
    local account=group_owner(host);local db=host.library_db
    if not keys or not account or not db or type(db.putProfileState)~='function' then return false end
    local ok,saved=pcall(db.putProfileState,db,GROUP_SELECTION_KEY,{keys=keys})
    if not ok or saved~=true or group_owner(host)~=account then return false end
    host.shelf_multi_groups=keys;host._shelf_multi_loaded=true;host._shelf_multi_owner=account
    return true
end

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
    if (tonumber(book.detail_updated_at) or 0) > 0 then return true end
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

function M:showBookshelf(restore_browse_position)
    if self._profile_view then self:closeWeReadUI() end
    local volatile = VolatileShelf.get(self)
    local cached = volatile and volatile.books or self.library_db and self.library_db:getShelf() or nil
    local archives = volatile and volatile.archives or self.library_db and self.library_db:getShelfArchives() or nil
    if cached and (#cached > 0 or archives ~= nil) then
        self:applyShelfSnapshot(cached, archives, volatile ~= nil)
        local position = restore_browse_position == true and self._shelf_browse_position
        if position and position.account ~= group_owner(self) then
            self._shelf_browse_position, self.shelf_view_pages = nil, nil
            position = nil
        end
        if position then
            self:showShelfView(position.mode, position.keyword, nil, { browse_position = position })
        else
            self:showShelfView("books")
        end
        if volatile and volatile.groups_incomplete then
            self:showTransientInfo(_("The bookshelf did not include group information. This temporary list is not saved; refresh again later."), 5)
        end
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
    local mark_navigation=package.loaded['weread.ui.my_mark_navigation']
    if mark_navigation and mark_navigation.cancel_incoming then mark_navigation.cancel_incoming(self) end
    local thought_replies = package.loaded['weread.ui.thought_replies']
    if thought_replies then thought_replies.cancel(self) end
    local reviews = package.loaded['weread.ui.native_book_reviews']
    if reviews then reviews.cancel(self) end
    local gateway_reviews = package.loaded['weread.ui.gateway_book_reviews']
    if gateway_reviews then gateway_reviews.cancel(self) end
    local notebooks=package.loaded['weread.ui.notebook_catalog']
    if notebooks then notebooks.cancel(self) end
    local offline_changes=package.loaded['weread.ui.offline_changes']
    if offline_changes then offline_changes.cancel(self) end
    local saved_searches=package.loaded['weread.ui.saved_searches']
    if saved_searches then saved_searches.cancel(self) end
    local downloads=package.loaded['weread.ui.download_library']
    if downloads then downloads.cancel(self) end
    if self.closeOfflineTimeUI then self:closeOfflineTimeUI() end
    local selection=package.loaded['weread.ui.selection_thought']
    if selection then selection.cancel(self) end
    self:cancelShelfCovers()
    if self.cancelBookCacheCleanup then self:cancelBookCacheCleanup() end
    if self.cancelMPDownloadRecovery then self:cancelMPDownloadRecovery() end
    if self.cancelMPArticleCleanup then self:cancelMPArticleCleanup() end
    if self.cancelWebRenewal then self:cancelWebRenewal() end
    require('weread.ui.catalog_request').cancel(self)
    require('weread.ui.download_recovery').cancel(self)
    if self.cancelMPArticleCatalog then self:cancelMPArticleCatalog() end
    if self.cancelMPArticleDownload then self:cancelMPArticleDownload() end
    if self.cancelMPLink then self:cancelMPLink() end
    if self.cancelPersonalUpload then self:cancelPersonalUpload() end
    if self.cancelPersonalOriginal then self:cancelPersonalOriginal() end
    if self.cancelMPArticleExport then self:cancelMPArticleExport() end
    if self.cancelMPArticleActions then self:cancelMPArticleActions() end
    if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
    if self.cancelBookSearch then self:cancelBookSearch() end
    if self.cancelShelfState then self:cancelShelfState() end
    if self.cancelReadingLanguage then self:cancelReadingLanguage() end
    if self.cancelLocalNotesExport then self:cancelLocalNotesExport() end
    if self.closeReaderLinkUI then self:closeReaderLinkUI() end
    if self.cancelCloudSourcePosition then self:cancelCloudSourcePosition() end
    if self.cancelShelfRefresh then self:cancelShelfRefresh() end
    if self.cancelDiscoveryRequest then self:cancelDiscoveryRequest() end
    if self.cancelBookMetadata then self:cancelBookMetadata() end
    if self.cancelBookReading then self:cancelBookReading() end
    local native_direct=package.loaded['weread.ui.native_direct_reading']
    if native_direct then native_direct.cancel(self) end
    local native_cleanup=package.loaded['weread.ui.native_direct_cleanup']
    if native_cleanup then native_cleanup.cancel(self) end
    local native_home=package.loaded['weread.ui.native_home_resume']
    if native_home then native_home.cancel(self) end
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
    if self.cancelReadStatsRequest then self:cancelReadStatsRequest() end
    if self.stopHomeStatusTimer then self:stopHomeStatusTimer() end
    if self.closeHomeControls then self:closeHomeControls(false) end
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
        "_saved_chapter_menu",
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
    local covers=package.loaded['weread.lib.shelf_cover_bitmap_cache'];if covers then covers.clear() end
    local copy_resume=package.loaded['weread.ui.native_direct_copy_resume'];if copy_resume then copy_resume.cancel(self) end
    local image_refresh=package.loaded['weread.ui.native_direct_image_refresh'];if image_refresh then image_refresh.cancel(self) end
    self._native_auto_time_epoch=(self._native_auto_time_epoch or 0)+1
    local auto_time=package.loaded['weread.lib.native_direct_time_auto'];if auto_time then auto_time.cancel(self) end
    self._native_auto_time_blocked=nil
    self._guest_recent_searches=nil
    require('weread.ui.prefetch_auth_recovery').cancel(self)
    self._prefetch_auth_attempts=nil
    self._resume_chapter_prefetch=nil
    self._chapter_open_intent=nil
    if self.downloader then self.downloader:cancelPrefetch('account_changed') end
    local offline=package.loaded['weread.ui.finish_offline']
    if offline then offline.cancel_sync(self);offline.cancel_dialog(self) end
    local member=package.loaded['weread.ui.membership_offline'];if member then member.cancel_sync(self);member.cancel_dialog(self) end
    VolatileShelf.clear(self)
    local personal=package.loaded['weread.ui.personal_marks']
    if personal then personal.detach(self) end
    require('weread.ui.mp_reader_open').cancel(self)
    if self._read_resume_token then require('weread.ui.read_resume').cancel(self) end
    if self.source_navigation then self.source_navigation:cancel() end
    if self.source_close then self.source_close:cancel() end
    if self.source_position then self.source_position:on_account_changed() end
    if self.native_renewal then self.native_renewal:cancel() end
    if self.native_authorization then self.native_authorization:cancel() end
    if self.offline_time then self.offline_time:stop("account_unavailable") end
    local time_source=package.loaded['weread.lib.native_direct_offline_time'];if time_source then time_source.cancel(self) end
    if self.read_report then self.read_report:stop("account_changed") end
    if self.progress_sync and self.progress_sync.on_account_changed then self.progress_sync:on_account_changed() end
    self:closeWeReadUI()
    self.discovery_state = nil
    self._home_browse_position = nil
    self._shelf_browse_position = nil
    self.discovery_categories = nil
    self.shelf_progress_retry_at = nil
    self.shelf_regular = nil
    self.shelf_mp = nil
    self.shelf_books = nil
    self.shelf_groups = nil
    self.shelf_cloud_groups = nil
    self.shelf_local_state,self.shelf_local_original,self.shelf_local_owner=nil,nil,nil
    self.shelf_ungrouped_known = nil
    self.shelf_group_key = nil
    self.shelf_multi_groups = nil
    self._shelf_multi_loaded = nil
    self._shelf_multi_owner = nil
    self.shelf_search_keyword = nil
    self.shelf_view_pages = nil
    if self.offline_time then self.offline_time:resume() end
    local time_options=self.settings and self.settings.get and self.settings:get('offline_time',{})
    if not auto_time and type(time_options)=='table' and time_options.enabled==true and time_options.auto_native==true then
        auto_time=require('weread.lib.native_direct_time_auto')
    end
    if auto_time then auto_time.start(self) end
    if personal then personal.attach(self) end
end

function M:applyShelfSnapshot(all_books, archives, preserve_volatile)
    local owner=self.shelf_view
    local metadata=self.book_metadata_context
    local rebase=metadata and metadata.begin_shelf_update and metadata.begin_shelf_update()
    local owned_status=owner and self._shelf_state_menu and owner._shelf_popup==self._shelf_state_menu
        and not self._book_detail_view and owner._shelf_snapshot_redraw
    if not preserve_volatile then VolatileShelf.clear(self) end
    load_group_selection(self)
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
    self.shelf_groups, self.shelf_ungrouped_known = ShelfGroups.list(archives, self.shelf_regular, _("Unnamed group"), _("Uncategorized"))
    -- Keep an active uncategorized selection empty when its last book is
    -- assigned to a group, rather than unexpectedly showing the full shelf.
    if self.shelf_ungrouped_known and #self.shelf_groups>0 and not ShelfGroups.find(self.shelf_groups,'__ungrouped__') then
        local selected=self.shelf_group_key=='__ungrouped__'
        for _i,key in ipairs(self.shelf_multi_groups or {}) do
            if key=='__ungrouped__' then selected=true;break end
        end
        if selected then
            self.shelf_groups[#self.shelf_groups+1]={key='__ungrouped__',label=_('Uncategorized'),books={}}
        end
    end
    self.shelf_cloud_groups=self.shelf_groups
    load_local_groups(self)
    load_local_pins(self)
    project_local_groups(self)
    if self.shelf_group_key and not ShelfGroups.unique(self.shelf_groups, self.shelf_group_key) then
        self.shelf_group_key = nil
        if self.shelf_view_pages then self.shelf_view_pages.books = 1 end
    end
    if rebase then rebase() end
    if owned_status and self.shelf_view==owner and not owner._shelf_closed then
        -- Account data changed beneath an owned status popup. Wait for it to
        -- close, then rebuild from the new snapshot rather than stale rows.
        local current=require('weread.ui.page_scope').capture(self,owner)
        require('weread.ui.shelf_popup').redraw(owner,function()
            if current() and not self._book_detail_view and not self._shelf_state_menu then
                owner._shelf_snapshot_redraw()
            end
        end)
    elseif owner and self._book_detail_view and owner._shelf_snapshot_redraw and not owner._shelf_closed then
        -- The detail must remain visible; bind its eventual return to the
        -- newly applied snapshot and the same account/document context.
        owner._shelf_snapshot_detail=self._book_detail_view
        owner._shelf_snapshot_current=require('weread.ui.page_scope').capture(self,owner)
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
        local groups_incomplete = type(result) == "table" and result.archive == nil
        if groups_incomplete then
            -- Never pair new membership with old groups or replace a complete
            -- snapshot with an answer that did not provide group information.
            local previous=VolatileShelf.get(self)
            local previous_saved=false
            if previous and previous.groups_incomplete then previous=nil end
            if not previous and self.library_db and type(self.library_db.getShelfArchives)=='function'
                and type(self.library_db.getShelf)=='function' then
                local archives=self.library_db:getShelfArchives()
                local books=archives~=nil and self.library_db:getShelf() or nil
                if type(archives)=='table' and type(books)=='table' then previous={books=books,archives=archives};previous_saved=true end
            end
            if previous then
                if view_options and view_options.on_loaded then view_options.on_loaded(previous_saved,previous,true) end
                self:showInfo(_("The bookshelf did not include group information. Your previous complete bookshelf is unchanged; refresh again later."))
                return
            end
        end
        local all_books = type(result) == "table"
            and type(result.books) == "table"
            and result.books
            or {}
        local archives = type(result) == "table" and type(result.archive) == "table" and result.archive or {}
        local snapshot_saved=not groups_incomplete and self.library_db~=nil and self.library_db:cacheShelf(all_books, archives)==true
        if snapshot_saved then UIManager:nextTick(function()
            if still_current() then
                require('weread.ui.finish_offline').pump(self,true)
                require('weread.ui.membership_offline').pump(self)
            end
        end) end
        self.shelf_active_source = type(result) == "table" and result._shelf_source or "gateway"
        if type(result) == "table" and result._native_fallback then
            self:showTransientInfo(_("E-Ink bookshelf is unavailable. Using the standard bookshelf for this refresh."), 3)
        elseif type(result) == "table" and result._gateway_fallback then
            self:showTransientInfo(_("The standard connection is unavailable. Using the Web bookshelf for this refresh."), 3)
        end
        local old_group_key = self.shelf_group_key
        self:applyShelfSnapshot(all_books, archives)
        local snapshot = { books = all_books, archives = archives, groups_incomplete = groups_incomplete or nil }
        if not snapshot_saved then VolatileShelf.remember(self, snapshot, result) end
        if view_options and view_options.on_loaded then
            view_options.on_loaded(snapshot_saved, snapshot, groups_incomplete)
            return
        end
        local next_options = {}
        for key, value in pairs(view_options or {}) do next_options[key] = value end
        next_options.prepared_shelf = nil
        next_options.refresh_progress = true
        if old_group_key ~= self.shelf_group_key then
            next_options.page, next_options.scroll_offset, next_options.browse_position = 1, nil, nil
        end
        -- showShelfView closes the current shelf while replacing it.
        if old_view and old_view~=self.shelf_view and not old_view._shelf_closed then UIManager:close(old_view) end
        self:showShelfView(
            view_options and view_options.mode or self.shelf_view_mode or "books",
            view_options and view_options.keyword or nil,
            nil,
            next_options
        )
        if not snapshot_saved and self.showTransientInfo then
            self:showTransientInfo(_(groups_incomplete and 'The bookshelf did not include group information. This temporary list is not saved; refresh again later.'
                or 'Could not save the bookshelf for offline use. The current list is still available.'), 5)
        end
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
    local missing, candidates = {}, {}
    for _, book in ipairs(visible) do
        if shelf_cover_url(book)
            and not cache:pathFor(book) then
            candidates[#candidates + 1] = book
        end
    end
    if #candidates == 0 then return end
    local online = require('weread.lib.network_link').available(self)
    for _,book in ipairs(candidates) do
        -- Legacy full-resolution cache entries can be converted while
        -- offline. A network request is only needed when no source exists.
        if online or cache:sourcePathFor(book) then missing[#missing + 1] = book end
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
            require('weread.ui.shelf_popup').redrawForMetadata(self,view,function()
                if generation~=self.shelf_cover_generation or self.shelf_view~=view then return end
                -- Closing book details rebuilds the parent from its cached
                -- data. Replacing it now would cancel that detail's actions.
                if self._book_detail_view then return end
                if options.on_redraw then options.on_redraw(view.page)
                else self:showShelfView(options.mode or "books", options.keyword, view, next_options) end
            end)
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
    old_view = old_view or self.shelf_view
    local carry_dirty
    if old_view and old_view._finish_dirty and old_view._finish_current and old_view._finish_current()
        and not require('weread.ui.finish_offline').reconcile_view(self,old_view) then carry_dirty=old_view._finish_dirty end
    options = options or {}
    if self.shelf_local_owner~=group_owner(self) then
        load_local_groups(self);project_local_groups(self)
    end
    -- Re-read when reopening so a concurrent writer's newer state is visible.
    local prior_pins,prior_owner=self.shelf_pins_state,self.shelf_pins_owner
    load_local_pins(self)
    local pin_model=require('weread.lib.local_shelf_pins')
    if options.prepared_shelf and (prior_owner~=self.shelf_pins_owner or not pin_model.same(prior_pins,self.shelf_pins_state)) then
        options.prepared_shelf,options.scroll_offset,options.rotation_anchor=nil,nil,nil;options.page=1
    end
    local local_pins=self.shelf_pins_owner==group_owner(self)
        and pin_model.index(self.shelf_pins_state) or nil
    mode = mode or "books"
    options.mode = mode
    options.keyword = keyword
    local skip_cover_fetch_once = options.skip_cover_fetch_once == true
    options.skip_cover_fetch_once = nil
    local skip_progress_fetch_once = options.skip_progress_fetch_once == true
    options.skip_progress_fetch_once = nil
    self:cancelShelfCovers()
    self.shelf_view_mode = mode
    self.shelf_search_keyword = keyword
    self.shelf_view_pages = self.shelf_view_pages or { books = 1, public_account = 1 }
    local saved_books = ReadAccess.book_lookup(self.settings)
    local recent_account = group_owner(self)
    local downloaded_cache = {}
    local shelf_settings = self.settings:get("shelf")
    local filters = self.shelf_filters or {}
    local order = shelf_settings.sort_order
    local reading_filter = filters.reading
    local needs_progress = order == 'progress_asc' or order == 'progress_desc'
        or reading_filter == 'progress_zero' or reading_filter == 'progress_active'
    local needle = ShelfSearch.prepare(keyword)
    local terms = ShelfSearch.terms(needle)
    local progress_by_id
    local function filtered(source, with_download_state)
        source = source or {}
        local query = needle
        if with_download_state and needs_progress and self.prepareShelfProgress then
            if query then
                local matches = {}
                for _, book in ipairs(source) do
                    if ShelfSearch.matches(book, query, terms) then matches[#matches + 1] = book end
                end
                source, query = matches, nil
            end
            progress_by_id = self:prepareShelfProgress(source, saved_books)
        end
        local result = {}
        for _, book in ipairs(source) do
            if (not query or ShelfSearch.matches(book, query, terms))
                and (not with_download_state or self:bookMatchesFilters(book, saved_books, downloaded_cache)) then
                if with_download_state and filters.download then
                    book._cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                end
                result[#result + 1] = book
            end
        end
        return sortBooks(result, order, with_download_state and saved_books or nil,
            recent_account, with_download_state and local_pins or nil)
    end
    local group = ShelfGroups.unique(self.shelf_groups, self.shelf_group_key)
    if self.shelf_group_key and not group then
        self.shelf_group_key = nil
        self.shelf_view_pages.books = 1
        options.prepared_shelf, options.page, options.rotation_anchor = nil, nil, nil
    end
    local multi=self.shelf_multi_groups or {}
    local grouped,multi_state=ShelfGroups.selected(self.shelf_groups,multi,self.shelf_regular)
    local multi_label=#multi>0 and (multi_state=='selected' and T(_('%1 groups'),tostring(#multi))
        or _('Selected groups unavailable; showing all books')) or nil
    if multi_state=='selected' then
        for _index,key in ipairs(multi) do
            local selected_group=ShelfGroups.unique(self.shelf_groups,key)
            if selected_group and selected_group.incomplete then
                multi_label=T(_('%1 (incomplete)'),multi_label);break
            end
        end
    end
    local prepared = options.prepared_shelf
    local group_source=#multi>0 and (grouped or self.shelf_regular) or (group and group.books or self.shelf_regular)
    local books = prepared and prepared.books or filtered(group_source, true)
    local accounts = prepared and prepared.accounts or filtered(self.shelf_mp, false)
    local cover_mode = shelf_settings.view_mode == "cover"
    local paged = cover_mode or shelf_settings.paginated ~= false
    local position = options.browse_position
    options.browse_position = nil
    local page = paged and (position and position.page or options.page or self.shelf_view_pages[mode] or 1) or 1
    local source = mode == "public_account" and accounts or books
    local navigation = self.discoveryNavigation and not options.on_select
        and self:discoveryNavigation("shelf") or nil
    local layout = LibraryView.getLayout(cover_mode, #source, mode, navigation and 54 or 0)
    local cover_layout = cover_mode and layout or nil
    local page_size = layout.page_size
    local focus_id = position and position.focus_book_id or options.focus_book_id
    local focus_book_index = (paged or position) and focus_id and LibraryView.bookIndex(source, focus_id)
    local first_index = position and position.book_id and LibraryView.bookIndex(source, position.book_id)
    local anchor = focus_book_index or options.rotation_anchor or first_index
    if paged and anchor then
        page=math.max(1,math.min(math.floor((anchor-1)/page_size)+1,
            math.max(1,math.ceil(#source/page_size))))
        options.page=page
    end
    options.rotation_anchor,options.focus_book_id=nil,nil
    local visible = source
    if paged then visible, page = shelf_page_items(source, page, page_size) end
    local lazy_status = mode == "books" and not paged
    local function book_status(visible_books, lookup, downloads)
        local times = {}
        for _, book in ipairs(visible_books) do
            -- Filtered results already carry the download state used for membership.
            if not filters.download then book._cached = self:isBookDownloaded(book, lookup, downloads) end
            if not cover_mode then times[book] = DiscoveryData.recent_time(book, lookup, recent_account) end
        end
        return times
    end
    local function visible_progress(visible_books, lookup, prepared_progress)
        if prepared_progress then
            -- Retain only the visible snapshots for the background refresh.
            local snapshots = {}
            for _, book in ipairs(visible_books) do
                local id = ShelfSnapshot.persisted_id(book)
                if id then snapshots[id] = prepared_progress[id] end
            end
            return snapshots
        elseif self.prepareShelfProgress then
            return self:prepareShelfProgress(visible_books, lookup)
        end
        return {}
    end
    local last_read_times, progress_snapshots
    if mode == "books" and not lazy_status then
        last_read_times = book_status(visible, saved_books, downloaded_cache)
        progress_snapshots = visible_progress(visible, saved_books, progress_by_id)
    end
    local cover_paths, cover_loading
    if cover_mode then
        cover_paths = {}
        cover_loading = {}
        local cache = self:getShelfCoverCache()
        local unresolved = {}
        for _, book in ipairs(visible) do
            local path = cache:pathFor(book)
            cover_paths[book] = path
            if not path and shelf_cover_url(book) then
                unresolved[#unresolved + 1] = book
            end
        end
        if #unresolved>0 then
            local online = require('weread.lib.network_link').available(self)
            for _,book in ipairs(unresolved) do
                cover_loading[book] = online or cache:sourcePathFor(book) ~= nil
            end
        end
    end
    if old_view then UIManager:close(old_view) end
    local view, update_progress
    local owner={account=self.library_db and self.library_db.accountKey and self.library_db:accountKey() or false,
        epoch=self.discovery_epoch or 0,session=self._reader_session_gen or false,
        document=self.ui and self.ui.document or false,books=self.shelf_regular,groups=self.shelf_groups,
        source=shelf_settings.source or 'auto',auth=self.settings.get_auth_scope and self.settings:get_auth_scope()}
    local function current()
        if self.shelf_view~=view or not view or view._shelf_closed
            or owner.account~=(self.library_db and self.library_db.accountKey and self.library_db:accountKey() or false)
            or owner.epoch~=(self.discovery_epoch or 0) or owner.session~=(self._reader_session_gen or false)
            or owner.document~=(self.ui and self.ui.document or false)
            or owner.books~=self.shelf_regular or owner.groups~=self.shelf_groups
            or owner.source~=(self.settings:get('shelf').source or 'auto') then return false end
        if self.settings.get_auth_scope then
            local auth=self.settings:get_auth_scope()
            if not owner.auth then return auth==nil end
            return auth and auth.vid==owner.auth.vid and auth.epoch==owner.auth.epoch
                and self.settings:auth_scope_matches(owner.auth)
        end
        return true
    end
    local function refresh_local_groups()
        if not current() then return end
        project_local_groups(self)
        if self.shelf_group_key and not ShelfGroups.unique(self.shelf_groups,self.shelf_group_key) then self.shelf_group_key=nil end
        local selected={}
        for _,key in ipairs(self.shelf_multi_groups or {}) do
            if key:sub(1,6)~='local:' or ShelfGroups.unique(self.shelf_groups,key) then selected[#selected+1]=key end
        end
        if #selected~=#(self.shelf_multi_groups or {}) then save_group_selection(self,selected) end
        local next_options={};for name,value in pairs(options) do next_options[name]=value end
        next_options.prepared_shelf,next_options.scroll_offset=nil,nil;next_options.page=1
        self:showShelfView('books',keyword,view,next_options)
    end
    local function refresh_local_pins()
        if not current() then return end
        local next_options={};for name,value in pairs(options) do next_options[name]=value end
        next_options.prepared_shelf,next_options.scroll_offset=nil,nil;next_options.page=1
        self:showShelfView('books',keyword,view,next_options)
    end
    local prepare_visible_status
    if lazy_status then
        local initial_lookup, initial_progress = saved_books, progress_by_id
        prepare_visible_status = function(visible_books)
            if not current() then return end
            local lookup = initial_lookup or ReadAccess.book_lookup(self.settings)
            local times = book_status(visible_books, lookup, {})
            local snapshots = visible_progress(visible_books, lookup, initial_progress)
            initial_lookup, initial_progress = nil, nil
            return snapshots, times
        end
    end
    if navigation then
        navigation = self:discoveryNavigation("shelf", current, function()
            if not recent_account then return end
            local browse = view:getBrowsePosition()
            browse.account, browse.mode, browse.keyword = recent_account, mode, keyword
            self._shelf_browse_position = browse
        end)
    end
    view = LibraryView.show({
        mode = mode,
        navigation = navigation,
        title = options.title,
        wp_enable = options.wp_enable,
        books = books,
        local_pins = local_pins,
        last_read_times = last_read_times,
        finish_pending = require('weread.ui.finish_offline').snapshot(self),
        accounts = accounts,
        groups = self.shelf_groups,
        group_membership_incomplete = self.shelf_ungrouped_known == false,
        group_key = self.shelf_group_key,
        group_keys = multi,
        group_label = multi_label or group and (group.incomplete and T(_('%1 (incomplete)'),group.label) or group.label),
        total_books = #(self.shelf_regular or {}),
        scroll_offset = position and position.scroll_offset or options.scroll_offset,
        browse_scroll = not paged and first_index and { index = first_index, inset = position.inset } or nil,
        focus_book_index = focus_book_index,
        keyword = keyword,
        empty_text = mode=='books' and #books==0 and (reading_filter=='progress_zero' or reading_filter=='progress_active')
            and _('No known progress matches. Update all bookshelf progress from the filter menu.') or nil,
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
        on_prepare_visible_status = prepare_visible_status,
        on_visible_changed = function()
            if current() and update_progress then update_progress() end
        end,
        on_close = function()
            if self.shelf_view == view then
                self.shelf_view = nil
                self:closeWeReadUI()
            end
        end,
        on_switch = function(new_mode)
            if not current() then return end
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = { books = books, accounts = accounts }
            next_options.page = self.shelf_view_pages[new_mode] or 1
            next_options.scroll_offset = nil
            self:showShelfView(new_mode, keyword, view, next_options)
        end,
        on_select_group = function(key)
            if not current() then return end
            if key and not ShelfGroups.unique(self.shelf_groups, key) then
                self:showInfo(_('This group is unavailable. Refresh the bookshelf and try again.'))
                return
            end
            if #multi>0 and not save_group_selection(self,{}) then
                self:showInfo(_('Could not save the selected groups.'));return
            end
            self.shelf_group_key = key
            local next_options = {}
            for name, value in pairs(options) do next_options[name] = value end
            next_options.prepared_shelf, next_options.scroll_offset = nil, nil
            next_options.page = 1
            self:showShelfView("books", keyword, view, next_options)
        end,
        on_select_groups = function(keys)
            if not current() then return end
            local selected=ShelfGroups.normalize(keys)
            if not selected then self:showInfo(_('Could not save the selected groups.'));return end
            for _i,key in ipairs(selected) do
                if not ShelfGroups.unique(self.shelf_groups,key) then
                    self:showInfo(_('Remove unavailable groups before applying.'));return
                end
            end
            if not save_group_selection(self,selected) then self:showInfo(_('Could not save the selected groups.'));return end
            self.shelf_group_key=nil
            local next_options={};for name,value in pairs(options) do next_options[name]=value end
            next_options.prepared_shelf,next_options.scroll_offset=nil,nil;next_options.page=1
            self:showShelfView('books',keyword,view,next_options)
        end,
        on_manage_local_groups = self.shelf_local_state and self.library_db and self.library_db.compareProfileState and function()
            if not current() then return end
            require('weread.ui.local_shelf_groups').open(self,view,current,refresh_local_groups)
        end or nil,
        on_display_change = function(key, value)
            if not current() then return end
            local shelf = self.settings:get("shelf")
            shelf[key] = value
            self.settings:set("shelf", shelf)
            self.settings:flush()
            options.page, options.scroll_offset = 1, nil
            self:showShelfView(mode, keyword, view, options)
        end,
        on_search = function()
            if not current() then return end
            self:showShelfSearchDialog(view, mode, keyword, options, current)
        end,
        on_refresh = function()
            if not current() then return end
            local refresh_options = {}
            for key, value in pairs(options) do refresh_options[key] = value end
            refresh_options.prepared_shelf = nil
            refresh_options.browse_position = view:getBrowsePosition()
            self:refreshBookshelf(view, refresh_options)
        end,
        on_sort = function()
            if not current() then return end
            self:showShelfSortOptions(function(result)
                if not current() then return end
                self.shelf_view_pages = { books = 1, public_account = 1 }
                options.prepared_shelf = nil
                options.page, options.scroll_offset = 1, nil
                options.skip_progress_fetch_once=type(result)=='table' and result.skip_progress_fetch_once==true
                self:showShelfView(mode, keyword, view, options)
            end,{owner=view,is_current=current})
        end,
        on_filter = function()
            if not current() then return end
            self:showShelfFilterOptions(function(result)
                if not current() then return end
                self.shelf_view_pages = { books = 1, public_account = 1 }
                options.prepared_shelf = nil
                options.page, options.scroll_offset = 1, nil
                options.skip_progress_fetch_once=type(result)=='table' and result.skip_progress_fetch_once==true
                self:showShelfView(mode, keyword, view, options)
            end,{owner=view,is_current=current})
        end,
        on_offline_changes = not options.on_select and function()
            if current() then require('weread.ui.offline_changes').show(self) end
        end or nil,
        on_import_mp_link = not options.on_select and function()
            if current() then require('weread.ui.mp_link').dialog(self,view,current) end
        end or nil,
        on_imported_mp_links = not options.on_select and function()
            if current() then require('weread.ui.mp_link').list(self,view,current) end
        end or nil,
        on_manage_mp_accounts = not options.on_select and function()
            if current() then require('weread.ui.mp_link').accounts(self,view,current) end
        end or nil,
        on_select = function(book, selected_mode)
            if not current() then return end
            if options.on_select then
                options.on_select(book, selected_mode, view)
            elseif selected_mode == "public_account" then
                self:showMPAccount(book)
            else
                self:showBookRecord(book)
            end
        end,
        on_hold = not options.on_select and function(book)
            if current() then
                local local_groups=require('weread.ui.local_shelf_groups')
                local action=local_groups.available(self,book) and function()
                    local_groups.book(self,view,book,current,refresh_local_groups)
                end or nil
                local pins=require('weread.ui.local_shelf_pins')
                local local_pin=pins.available(self,book) and {
                    pinned=require('weread.lib.local_shelf_pins').contains(self.shelf_pins_state,book),
                    callback=function() pins.toggle(self,book,current,refresh_local_pins) end,
                } or nil
                require('weread.ui.book_quick_actions').open(self, view, book, current,action,local_pin)
            end
        end or nil,
        on_page_changed = function(new_page)
            if not current() then return end
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
    view._rotation_redraw=function()
        if not current() or self._book_detail_view then return end
        local next_options={};for key,value in pairs(options) do next_options[key]=value end
        next_options.prepared_shelf={books=books,accounts=accounts}
        if paged then next_options.rotation_anchor=(view.page-1)*view.page_size+1
        else next_options.scroll_offset=view:getScrollOffset() end
        self:showShelfView(mode,keyword,view,next_options)
    end
    view._finish_dirty=carry_dirty
    view._finish_current=current
    view._shelf_snapshot_redraw=function()
        local next_options={};for key,value in pairs(options) do next_options[key]=value end
        next_options.prepared_shelf=nil
        next_options.browse_position=view:getBrowsePosition()
        if view:getFocusedBookId() then self:showShelfView(mode,keyword,view,next_options)
        else
            require('weread.ui.finish_offline').redraw_preserving_focus(self,view,function()
                self:showShelfView(mode,keyword,view,next_options)
            end)
        end
    end
    view._finish_redraw = function()
        if not current() then return end
        local next_options={};for key,value in pairs(options) do next_options[key]=value end
        next_options.prepared_shelf={books=books,accounts=accounts};next_options.page=view.page
        next_options.scroll_offset=view:getScrollOffset()
        require('weread.ui.finish_offline').redraw_preserving_focus(self,view,function()
            self:showShelfView(mode,keyword,view,next_options)
        end)
    end
    view._prepare_detail_return = function(snapshot_current)
        local owned=current()
        if not owned and not snapshot_current then return end
        if owned then require('weread.ui.finish_offline').reconcile_view(self,view) end
        return function()
            if self.shelf_view==view and not view._shelf_closed then view._shelf_snapshot_redraw() end
        end
    end
    if mode == "books" and self.prepareShelfProgress then
        local force = options.refresh_progress
        options.refresh_progress = nil
        update_progress = function(refresh)
            local progress_books = paged and visible or view:getVisibleBooks()
            local snapshots = lazy_status and view:prepareVisibleStatus(progress_books) or progress_snapshots
            self:refreshVisibleShelfProgress(view, progress_books, snapshots, {
                force = refresh,
                on_redraw = function()
                    require('weread.ui.shelf_popup').redrawForMetadata(self,view,function()
                        if not current() or self._book_detail_view then return end
                        local next_options = {}
                        for key, value in pairs(options) do next_options[key] = value end
                        if reading_filter~='progress_zero' and reading_filter~='progress_active' then
                            next_options.prepared_shelf = { books = books, accounts = accounts }
                        else
                            next_options.prepared_shelf = nil
                        end
                        next_options.page = view.page
                        next_options.scroll_offset = view:getScrollOffset()
                        self:showShelfView(mode, keyword, view, next_options)
                    end)
                end,
            })
        end
        if skip_progress_fetch_once then
            if self.cancelShelfProgress then self:cancelShelfProgress() end
        else update_progress(force) end
    elseif self.cancelShelfProgress then self:cancelShelfProgress() end
    if cover_mode and not skip_cover_fetch_once then
        local fetch_options = {}
        for key, value in pairs(options) do fetch_options[key] = value end
        fetch_options.prepared_books = books
        fetch_options.prepared_accounts = accounts
        self:fetchVisibleShelfCovers(view, source, fetch_options)
    end
end

function M:showShelfSearchDialog(view, mode, keyword, options, is_current)
    local Popup=require('weread.ui.shelf_popup')
    local dialog
    local function current()
        return self.shelf_view==view and Popup.current(view,dialog) and (not is_current or is_current())
    end
    dialog = InputDialog:new{
        title = _("Search shelf"),
        input = keyword or "",
        input_type = "text",
        buttons = {{
            {
                text = _("Clear"),
                callback = self:safeCallback(_("Clear"), function()
                    if not current() then return end
                    Popup.close(view)
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
                    if not current() then return end
                    local value = require("weread.lib.search_query").trim(dialog:getInputText())
                    Popup.close(view)
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
    Popup.show(view,dialog,function(widget) self:showInputDialog(widget) end)
end

sortBooks = function(books, sort_order, saved_books, account, local_pins)
    if sort_order == "default" or not sort_order then
        return ShelfFlags.pinned_first(books,local_pins)
    end
    local by_time = sort_order == "time_desc" or sort_order == "time_asc"
    local by_name = sort_order == "name_asc" or sort_order == "name_desc"
    local by_author = sort_order == "author_asc" or sort_order == "author_desc"
    local by_progress = sort_order == "progress_asc" or sort_order == "progress_desc"
    if not by_time and not by_name and not by_author and not by_progress then return ShelfFlags.pinned_first(books,local_pins) end
    local descending = sort_order == "time_desc" or sort_order == "name_desc" or sort_order == "author_desc" or sort_order == "progress_desc"
    local entries, sorted = {}, {}
    local trim = (by_author or by_name) and require("weread.lib.search_query").trim
    for i, book in ipairs(books) do
        local value
        if by_time then
            value = DiscoveryData.recent_time(book,saved_books,account) or 0
        elseif by_progress then
            local progress=book._shelf_progress
            if type(progress)=='number' and progress==progress and progress>=0 and progress<=100 then value=progress end
        elseif by_author then
            local author = trim(book.author)
            if author == "" then author = trim(book.authors) end
            if author ~= "" then value = ShelfSearch.prepare(author) end
        else
            local title = trim(book.title)
            if title ~= "" then value = ShelfSearch.prepare(title) end
        end
        entries[i] = { book = book, value = value, index = i }
    end
    -- Lua's table.sort is not stable. Preserve the shelf order for equal
    -- values, including the many books with no recent-reading timestamp.
    table.sort(entries, function(a, b)
        if a.value == b.value then return a.index < b.index end
        if by_author or by_name or by_progress then
            if a.value == nil then return false end
            if b.value == nil then return true end
        end
        if descending then return a.value > b.value end
        return a.value < b.value
    end)
    for i, entry in ipairs(entries) do sorted[i] = entry.book end
    return ShelfFlags.pinned_first(sorted,local_pins)
end

function M:showShelfPage()
    local books = self.shelf_books or {}
    if #books == 0 then
        self:showInfo(_("Your WeRead shelf is empty."))
        return
    end
    local menu, buildItems
    load_local_pins(self)
    local function refresh()
        menu:switchItemTable(nil, buildItems())
    end
    buildItems = function()
        local items = self:shelfToolbarItems(true, refresh)
        local saved_books = self.settings:get("books", {})
        local account = group_owner(self)
        local order=self.settings:get("shelf").sort_order
        local reading_filter=self.shelf_filters and self.shelf_filters.reading
        if (order=='progress_asc' or order=='progress_desc' or reading_filter=='progress_zero' or reading_filter=='progress_active')
            and self.prepareShelfProgress then self:prepareShelfProgress(books,saved_books) end
        local local_pins=self.shelf_pins_owner==account and require('weread.lib.local_shelf_pins').index(self.shelf_pins_state) or nil
        local sorted = sortBooks(books,order,saved_books,account,local_pins)
        local downloaded_cache = {}
        self._shelf_saved_books = saved_books
        for _i, book in ipairs(sorted) do
            if self:bookMatchesFilters(book, saved_books, downloaded_cache) then
                local is_cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                local right_text
                if ShelfFlags.display(book,'finished')==true then
                    right_text = _("Done")
                elseif (order=='progress_asc' or order=='progress_desc') and type(book._shelf_progress)=='number' then
                    right_text = ShelfProgress.label(book._shelf_progress,book._shelf_progress_local,book._shelf_progress_exact) or ''
                else
                    right_text = ShelfTime.date(DiscoveryData.recent_time(book,saved_books,account)) or ""
                end
                local labels={}
                local id=local_pins and require('weread.lib.shelf_snapshot').persisted_id(book)
                if id and local_pins[id] then labels[#labels+1]=_('Local pin') end
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
                        return rightStatus(self:isBookDownloaded(book,self._shelf_saved_books or {}))
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
    local book_id = ShelfSnapshot.persisted_id(book)
    if not book_id then self:showInfo(_("Saved book information does not match. Check the local cache before opening."));return end
    if WeRead.is_mp_book(book_id) then
        self:showMPAccount(book)
        return
    end
    local account_key = self.library_db and self.library_db:accountKey() or nil
    local saved,conflict,legacy_key=ReadAccess.cached_book_for_update(books,book_id)
    if conflict then
        self:showInfo(_("Saved book information does not match. Check the local cache before opening."));return
    end
    -- Safely migrate a legacy numeric index to its exact string key, avoiding
    -- duplicate entries that could overwrite the same stored book on flush.
    if legacy_key then books[legacy_key]=nil end
    saved=saved or {}
    if account_key and saved._library_account_key
        and saved._library_account_key ~= account_key then
        local previous=saved
        saved = keep_local_cache(previous)
        -- Account-scoped settings already project only this account's reading
        -- state; changing metadata ownership must not erase that checkpoint.
        if self.settings.account_state_scope then
            for key,value in pairs(previous) do
                if BookStore.is_reading_field(key) then saved[key]=value end
            end
        end
    end
    local source=saved.detail_source
    local saved_details = saved._library_account_key == account_key and (tonumber(saved.detail_updated_at) or 0) > 0
        and (account_key and (source == 'native' or source == 'web' or source == 'gateway')
            or not account_key and source == 'public')
    local cached = self.library_db and self.library_db:getBook(book_id) or nil
    for key, value in pairs(cached or {}) do
        if saved[key] == nil and not BookStore.is_reading_field(key) then saved[key] = value end
    end
    for key, value in pairs(book) do
        if value ~= nil and key ~= "_cached" and key ~= "_public_info"
            and not BookStore.is_reading_field(key) then saved[key] = value end
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
    -- The bounded public excerpt is a display fallback, not full metadata.
    -- Keep it out of the book record so it cannot suppress a later refresh.
    local public_info=require('weread.lib.public_book_info').project(book._public_info)
    if public_info then
        local display={};for key,value in pairs(saved) do display[key]=value end
        for _,key in ipairs({'intro','publisher','translator'}) do
            if (display[key]==nil or display[key]=='') and public_info[key]~=nil then display[key]=public_info[key] end
        end
        if display.newRating==nil and display.newRatingCount==nil then
            display.newRating,display.newRatingCount=public_info.newRating,public_info.newRatingCount
        end
        saved=display
    end
    if not saved_details and not has_book_details(cached) and not (options and options.verified_metadata) then
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

function M:showBookMenu(book, options)
    local book_id = ShelfSnapshot.persisted_id(book)
    if not book_id then self:showInfo(_("Saved book information does not match. Check the local cache before opening."));return end
    local saved,conflict=ReadAccess.load_cached_book(self.settings,book_id)
    if conflict then self:showInfo(_("Saved book information does not match. Check the local cache before opening."));return end
    saved=saved or book
    local BookDetailView = require("weread.ui.book_detail_view")
    if type(book.chapters) ~= "table" then
        book.chapters = self.library_db and self.library_db:getChapters(book_id) or nil
        if type(book.chapters) ~= "table" then
            local legacy_catalog = Content.load_catalog_cache(self.client, self.settings, book)
            if legacy_catalog and self.library_db then
                self.library_db:putChapters(book_id, legacy_catalog)
            end
        end
    end
    local probes = {}
    local function exists(path)
        if type(path) ~= 'string' or path == '' then return false end
        if probes[path] == nil then probes[path] = file_exists(path) end
        return probes[path]
    end
    local cached_path = self:getFullBookCachePath(saved, exists)
    local is_full_cached = exists(cached_path)
    local has_cache = exists(saved.cached_full_book) or exists(saved.cached_file)
    book.cached_full_book = is_full_cached and cached_path or nil
    local cached_chapter_count,any_cached_chapter = 0,false
    local catalog_uids,seen_paths={},{}
    local total_chapters = type(book.chapters) == "table" and #book.chapters or nil
    if not is_full_cached then
        for _i,chapter in ipairs(book.chapters or {}) do
            local uid=chapter.chapterUid or chapter.chapterId
            if uid~=nil then catalog_uids[tostring(uid)]=true end
        end
    end
    if not is_full_cached or not has_cache then
        for uid, path in pairs(type(saved.cached_chapters)=='table' and saved.cached_chapters or {}) do
            if exists(path) then
                any_cached_chapter=true
                if is_full_cached then break end
                if (not total_chapters or catalog_uids[tostring(uid)]) and not seen_paths[path] then
                    cached_chapter_count = cached_chapter_count + 1;seen_paths[path]=true
                end
            end
        end
    end
    has_cache = has_cache or any_cached_chapter
    local chapter_status = is_full_cached and _("Full book cached") or total_chapters
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
    local direct_cached=options and options.read_saved_native
        or self.nativeChapterCachePresent and self:nativeChapterCachePresent(book_id)
    if not direct_cached or any_cached_chapter or is_full_cached then statuses[#statuses + 1] = chapter_status end
    if direct_cached then
        statuses[#statuses+1]=_('E-Ink chapters saved')
    end

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
    local category_name = book.categoryName
    if category_name == nil or category_name == "" then category_name = book.category end
    local category = format_field(_("Category"), category_name)
    if category then metadata[#metadata + 1] = { text = category } end
    local words = format_field(_("Word count"), word_count)
    if words then metadata[#metadata + 1] = { text = words } end
    add_row("ISBN", book.isbn, _("Rating"), rating)

    local view,cache_scope
    local open_chapter_list = self:safeCallback(_("Chapter list"), function()
        self:showChapterList(book, function()
            local latest = ReadAccess.load_cached_book(self.settings,book_id) or book
            if view then UIManager:close(view) end
            self:showBookMenu(latest)
        end)
    end)
    local review_action = {
        text = self.settings.is_api_configured and not self.settings:is_api_configured()
            and _("Latest reviews") or _("Recommended / Latest"),
        callback = self:safeCallback(_("Book reviews"), function()
            self:showBookReviews(book)
        end),
    }
    local actions = {}
    local Quick=require('weread.ui.book_quick_actions')
    local detail_id=tostring(book_id or '')
    local member_shortcut,finish_shortcut=Quick.available(self,detail_id)
    local detail_account=self.library_db and self.library_db:accountKey()
    local detail_session,detail_epoch,detail_document=self._reader_session_gen,self.discovery_epoch or 0,self.ui and self.ui.document
    local detail_auth=self.settings.get_auth_scope and self.settings:get_auth_scope()
    local function detail_current()
        if self._book_detail_view~=view or not detail_account or self.library_db:accountKey()~=detail_account
            or self._reader_session_gen~=detail_session or (self.discovery_epoch or 0)~=detail_epoch
            or (self.ui and self.ui.document)~=detail_document then return false end
        if self.settings.get_auth_scope then
            local auth=self.settings:get_auth_scope()
            if not detail_auth then return auth==nil end
            return auth and auth.vid==detail_auth.vid and auth.epoch==detail_auth.epoch
                and self.settings:auth_scope_matches(detail_auth)
        end
        return true
    end
    if member_shortcut then actions[#actions+1]={text=_('Change cloud membership'),callback=self:safeCallback(_('Shelf status'),function()
        Quick.change(self,detail_id,'weread.ui.shelf_membership_write',detail_current)
    end)} end
    if finish_shortcut then actions[#actions+1]={text=_('Change finished mark'),callback=self:safeCallback(_('Shelf status'),function()
        Quick.change(self,detail_id,'weread.ui.finish_change',detail_current)
    end)} end
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
    if self.showMyCloudMarks and require('weread.lib.my_cloud_marks').display_id(tostring(book_id)) then
        local account=self.library_db and self.library_db:accountKey()
        local session,document=self._reader_session_gen,self.ui and self.ui.document
        actions[#actions+1]={text=_('My cloud highlights'),callback=self:safeCallback(_('My cloud highlights'),function()
            if self._book_detail_view==view and account==self.library_db:accountKey()
                and session==self._reader_session_gen and document==(self.ui and self.ui.document) then
                self:showMyCloudMarks(tostring(book_id))
            end
        end)}
    end
    if self.showMyCloudThoughts and require('weread.lib.my_cloud_marks').display_id(tostring(book_id)) then
        local account=self.library_db and self.library_db:accountKey()
        local session,document=self._reader_session_gen,self.ui and self.ui.document
        actions[#actions+1]={text=_('My cloud thoughts'),callback=self:safeCallback(_('My cloud thoughts'),function()
            if self._book_detail_view==view and account==self.library_db:accountKey()
                and session==self._reader_session_gen and document==(self.ui and self.ui.document) then
                self:showMyCloudThoughts(tostring(book_id))
            end
        end)}
    end
    if self.showMyCloudBookmarks and require('weread.lib.my_cloud_marks').display_id(tostring(book_id)) then
        local account=self.library_db and self.library_db:accountKey()
        local session,document=self._reader_session_gen,self.ui and self.ui.document
        actions[#actions+1]={text=_('My cloud bookmarks'),callback=self:safeCallback(_('My cloud bookmarks'),function()
            if self._book_detail_view==view and account==self.library_db:accountKey()
                and session==self._reader_session_gen and document==(self.ui and self.ui.document) then
                self:showMyCloudBookmarks(tostring(book_id))
            end
        end)}
    end
    local original=require('weread.lib.personal_original')
    local original_account=self.library_db and self.library_db.accountKey and self.library_db:accountKey()
    local original_session=self._reader_session_gen
    if type(book_id)=='string' and book_id:match('^CB_[A-Za-z0-9]+$') and original_account then
        actions[#actions+1]={text=_('Choose or change local PDF'),callback=self:safeCallback(_('Choose a local PDF'),function()
            if self._book_detail_view==view and original_account==self.library_db:accountKey()
                and original_session==self._reader_session_gen then require('weread.ui.personal_original').start(self,book,view) end
        end)}
    end
    local original_record=original.snapshot(self,tostring(book_id))
    if original_record and original_account then
        actions[#actions+1]={text=_('Remove local PDF association'),callback=self:safeCallback(_('Remove association'),function()
            if self._book_detail_view==view and original_account==self.library_db:accountKey()
                and original_session==self._reader_session_gen then
                require('weread.ui.personal_original').forget(self,book,view,original_record)
            end
        end)}
    end
    if original.resolve(self,tostring(book_id)) then
        actions[#actions+1]={text=_('Read original PDF (local only, no cloud sync)'),
            callback=self:safeCallback(_('Read original PDF'),function()
                if self._book_detail_view~=view or not original_account
                    or original_account~=self.library_db:accountKey() or original_session~=self._reader_session_gen then return end
                local path=original.resolve(self,tostring(book_id))
                if not path then self:showInfo(_('The local original PDF is unavailable or has changed.'));return end
                if not original.arm(path) then return end
                local opened,err=pcall(self.openFile,self,path)
                if not opened then original.disarm(path);error(err) end
            end)}
    end
    if any_cached_chapter and not is_full_cached then
        actions[#actions+1]={text=_('Read cached copy'),callback=self:safeCallback(_('Read cached copy'),function()
            if not cache_scope or not cache_scope() or self._book_detail_view~=view then return end
            local latest=self.settings:get_book(book_id) or book
            self:readCachedCopy(latest,view)
        end)}
    end
    if any_cached_chapter or is_full_cached then
        actions[#actions+1]={text=_('Downloaded chapters'),callback=self:safeCallback(_('Downloaded chapters'),function()
            if cache_scope and cache_scope() and self._book_detail_view==view then
                self:showSavedChapters(book_id,view)
            end
        end)}
    end
    local native_resume_action, download_native_action
    if require('weread.lib.native_position_protocol').id(book_id) then
        local resume=saved.native_home_resume and require('weread.ui.native_home_resume')
        if resume and resume.can_resume(self,saved,book_id) then
            local resume_scope=self.settings:get_auth_scope()
            local resume_session=self._reader_session_gen
            native_resume_action=self:safeCallback(_('Continue saved E-Ink chapter'),function()
                if self._book_detail_view~=view or self._reader_session_gen~=resume_session
                    or not self.settings:auth_scope_matches(resume_scope) then return end
                local latest=self.settings:get_book(book_id)
                if resume.can_resume(self,latest,book_id) then resume.open_detail(self,latest,book_id,view)
                else self:showInfo(_('The saved E-Ink chapter changed or could not be verified. Choose a saved chapter instead.')) end
            end)
        end
        actions[#actions+1]={text=_('Read E-Ink chapter'),callback=self:safeCallback(_('Read E-Ink chapter'),function()
            if self._book_detail_view==view then require('weread.ui.native_direct_reading').start(self,book,view) end
        end)}
        actions[#actions+1]={text=_('Download E-Ink chapters'),callback=self:safeCallback(_('Download E-Ink chapters'),function()
            if self._book_detail_view==view then require('weread.ui.native_direct_reading').start(self,book,view,{batch=true}) end
        end)}
        local read_saved_native=self:safeCallback(_('Read saved E-Ink chapter'),function()
            if self._book_detail_view==view then require('weread.ui.native_direct_reading').start(self,book,view,{cached=true}) end
        end)
        actions[#actions+1]={text=_('Read saved E-Ink chapter'),callback=read_saved_native}
        if options and options.read_saved_native then download_native_action=read_saved_native end
        local native_scope=self.settings.get_auth_scope and self.settings:get_auth_scope()
        if native_scope and require('weread.lib.native_direct_cache').book_directory(self.settings,native_scope.vid,detail_id) then
            actions[#actions+1]={text=_('Clear unused E-Ink chapters'),callback=self:safeCallback(_('Clear unused E-Ink chapters'),function()
                if self._book_detail_view==view then require('weread.ui.native_direct_cleanup').start(self,book,view) end
            end)}
        end
    end
    if has_cache then
        local function clear_cache(full_path)
            if self._book_detail_view~=view or not cache_scope or not cache_scope() then return end
            self:confirmClearBookCache(book_id, book.title or book_id, function()
                local latest = ReadAccess.load_cached_book(self.settings,book_id) or book
                UIManager:close(view)
                self:showBookMenu(latest)
            end, full_path)
        end
        if is_full_cached then
            actions[#actions + 1] = {
                text = _("Remove only the full-book copy"),
                callback = self:safeCallback(_("Remove only the full-book copy"), function() clear_cache(cached_path) end),
            }
        end
        actions[#actions + 1] = {
            text = _("Clear book cache"),
            callback = self:safeCallback(_("Clear book cache"), function() clear_cache() end),
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
            text = native_resume_action and _('▤ Continue reading') or _("▤ Read"),
            callback = native_resume_action or download_native_action or self:safeCallback(_("Read"), function()
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
                local reviews = package.loaded['weread.ui.native_book_reviews']
                if reviews then reviews.cancel(self) end
                local gateway_reviews = package.loaded['weread.ui.gateway_book_reviews']
                if gateway_reviews then gateway_reviews.cancel(self) end
                if self.cancelMyCloudMarks then self:cancelMyCloudMarks() end
                if self.cancelShelfState then self:cancelShelfState() end
                self:cancelBookMetadata()
                self:cancelBookReading()
                local native_direct=package.loaded['weread.ui.native_direct_reading']
                if native_direct then native_direct.cancel(self) end
                local native_cleanup=package.loaded['weread.ui.native_direct_cleanup']
                if native_cleanup then native_cleanup.cancel(self) end
                local native_home=package.loaded['weread.ui.native_home_resume']
                if native_home and self._native_home_resume and self._native_home_resume.view==view then native_home.cancel(self) end
                require('weread.ui.catalog_request').cancel(self)
                require('weread.ui.download_recovery').cancel(self)
                if self.cancelDiscoveryRequest then self:cancelDiscoveryRequest() end
                local parent = self.shelf_view
                local snapshot_current=parent and parent._shelf_snapshot_detail==view
                    and parent._shelf_snapshot_current and parent._shelf_snapshot_current()
                self._book_detail_view = nil
                local resume = parent and parent._prepare_detail_return and parent._prepare_detail_return(snapshot_current)
                self.discovery_epoch = (self.discovery_epoch or 0) + 1
                -- Rebuild the retained parent with fresh callbacks after the
                -- detail's epoch is invalidated; old deferred taps stay stale.
                if resume then resume() end
            end
        end,
    })
    view._excerpt_book={book_id=book_id,title=book.title,author=book.author or book.authors}
    self._book_detail_view = view
    cache_scope=require('weread.ui.page_scope').capture(self,self.shelf_view)
    return view
end

function M:showBookReviewDetail(book, review, mode, options)
    options = options or {}
    local author = review.author ~= "" and review.author or _("Anonymous")
    local metadata = {}
    if review.rating > 0 then
        metadata[#metadata + 1] = T(
            _("Score %1 / 5"), BookReviews.format_rating(review.rating)
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
    if review.attachment_state == 'partial' then
        text[#text + 1] = _('Some review attachments could not be displayed.')
    end

    local buttons = {}
    if options.on_replies then buttons[#buttons+1]={{text = _("View replies"), callback = options.on_replies}} end
    if options.on_image and review.attachment_state then
        local urls = require('weread.lib.thought_attachments').decode(review.attachment_urls) or {}
        for index in ipairs(urls) do
            local selected=index
            buttons[#buttons+1]={{id='review_image_'..index,text=T(_('View review image %1'),tostring(index)),
                callback=function() options.on_image(selected) end}}
        end
    end

    local viewer = TextViewer:new{
        title = mode == "latest" and _("Latest review") or _("Recommended review"),
        text = table.concat(text, "\n"),
        text_type = "general",
        auto_para_direction = true,
        buttons_table = #buttons>0 and buttons or nil,
        add_default_buttons = #buttons>0 and true or nil,
        close_callback = options.on_close,
    }
    UIManager:show(viewer)
    return viewer
end

function M:showBookReviews(book)
    local native_ui = package.loaded['weread.ui.native_book_reviews']
    if native_ui then native_ui.cancel(self) end
    local gateway_ui = package.loaded['weread.ui.gateway_book_reviews']
    if gateway_ui then gateway_ui.cancel(self) end
    if not require('weread.lib.network_link').available(self) then
        if require('weread.ui.gateway_book_reviews').open(self, book) then return true end
        return require('weread.ui.native_book_reviews').open(self, book)
    end
    if self.settings and self.settings.is_api_configured and not self.settings:is_api_configured() then
        local selected = require('weread.lib.native_book_reviews_source').capture(self.settings)
        return require('weread.ui.native_book_reviews').open(self, book, selected)
    end
    if not self:requireLogin(false, true) then return false end
    local selected = require('weread.lib.gateway_book_reviews_source').capture(self.settings)
    if not selected or not selected.api_key then
        self:showInfo(_('Book review authorization changed. Please sign in again.'))
        return false
    end
    local opened = require('weread.ui.gateway_book_reviews').open(self, book, selected)
    if not opened then self:showInfo(_('Could not load book reviews. Please try again.')) end
    return opened
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
    self:fetchMPLatest(book)
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

function M:fetchMPLatest(book)
    return require('weread.ui.mp_catalog').start(self,book,{latest=true})
end

function M:cancelMPArticleCatalog()
    return require('weread.ui.mp_catalog').cancel(self)
end

function M:cancelMPLink()
    return require('weread.ui.mp_link').cancel(self)
end

function M:cancelPersonalOriginal()
    if self._personal_original_attach then require('weread.ui.personal_original').cancel(self) end
end
function M:cancelPersonalUpload()
    if not self._personal_upload_ui then return end
    return require('weread.ui.personal_upload').cancel(self)
end

function M:getCachedMPArticles(book_id)
    local books = self.settings:get("books", {})
    local record = books[book_id]
    if record and record.mp_articles then
        return record.mp_articles
    end
    return nil
end

function M:cacheMPArticles(book_id, articles, options)
    local books = self.settings:get("books", {})
    books[book_id] = books[book_id] or {}
    books[book_id].mp_articles = articles
    books[book_id].mp_articles_time = os.time()
    books[book_id].mp_latest_only = options and options.latest==true or nil
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
    local record=self.settings:get('books',{})[book.book_id or book.bookId]
    if type(record)=='table' and record.mp_latest_only then
        items[#items+1]={text=_("Latest article and saved articles; earlier articles may be unavailable."),select_enabled=false}
    end
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
        text = _("Refresh latest article"),
        callback = self:safeCallback(_("Refresh latest article"), function()
            if not current() then return end
            self:fetchMPLatest(book)
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
    local reader_context=require('weread.lib.reader_context')
    local valid_id,requested_id=pcall(reader_context.book_id,book)
    if not valid_id then
        self:showInfo(_("Could not load this book’s chapter list. Check your connection and login, then try again."))
        return
    end
    local current = require('weread.ui.page_scope').capture(self,self.shelf_view)
    local chapter_view = force_refresh and self._chapter_list_view or nil
    self:runOnlineTask(_("Loading chapter list..."), function()
        local same_id,current_id=pcall(reader_context.book_id,book)
        if not same_id or current_id~=requested_id or not current()
            or chapter_view and (self._chapter_list_view~=chapter_view or chapter_view._catalog_closed) then return end
        require('weread.ui.catalog_request').start(self,book,function(chapters_or_err)
            book.chapters=chapters_or_err
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
        end,{current=current,chapter_view=chapter_view})
    end)
end

-- Match the chapter-opening rules when presenting offline availability.
-- A combined EPUB may contain only part of the catalog, so check each UID.
local function chapter_cache_lookup(host,book)
    local claims=require('weread.lib.chapter_cache_claim')
    local identity=require('weread.lib.reader_context')
    local cache={}
    local full=host.getFullBookCachePath and host:getFullBookCachePath(book) or book.cached_full_book
    local combined=full and file_exists(full) and claims.combined(book,full)
    return function(uid)
        local cached=ReadAccess.cached_chapter(book.cached_chapters,uid)
        if cached and file_exists(cached) and claims.usable(book,cached,uid,cache) then return true end
        local ok,id=pcall(identity.identifier,uid,true)
        return ok and combined and combined.items['chapter_'..id]==true or false
    end, combined
end

local function saved_chapter_rows(host, book, catalog)
    local identity = require('weread.lib.reader_context')
    local is_cached, combined = chapter_cache_lookup(host, book)
    local rows, seen = {}, {}
    local function append(uid, title, position)
        local ok, id = pcall(identity.identifier, uid, true)
        if not ok or seen[id] or not is_cached(id) then return end
        seen[id] = true
        rows[#rows + 1] = { chapterUid = id, position = position,
            title = type(title)=='string' and title~='' and title or T(_('Chapter ID %1'), id) }
    end
    for index, chapter in ipairs(type(catalog)=='table' and catalog or {}) do
        if type(chapter)=='table' then append(chapter.chapterUid or chapter.chapterId, chapter.title, index) end
    end
    for _, member in ipairs(combined and combined.order or {}) do
        append(member:match('^chapter_(.+)$'))
    end
    local other_ids = {}
    for uid in pairs(type(book.cached_chapters)=='table' and book.cached_chapters or {}) do
        local ok, id = pcall(identity.identifier, uid, true)
        if ok and not seen[id] then other_ids[#other_ids + 1] = id end
    end
    table.sort(other_ids, function(a,b) return #a < #b or #a == #b and a < b end)
    for _, uid in ipairs(other_ids) do append(uid) end
    return rows
end

function M:showSavedChapters(book_id, detail)
    if self._book_detail_view ~= detail then return end
    if self._saved_chapter_menu then UIManager:close(self._saved_chapter_menu) end
    local latest = ReadAccess.load_cached_book(self.settings, book_id)
    if not latest then self:showInfo(_('No downloaded chapters found.')); return end
    local catalog = self.library_db and self.library_db:getChapters(book_id)
    if type(catalog)~='table' or #catalog==0 then
        catalog = Content.load_catalog_cache(self.client, self.settings, latest)
    end
    local rows = saved_chapter_rows(self, latest, catalog)
    local ChapterSearch = require('weread.ui.chapter_search')
    local Popup = require('weread.ui.shelf_popup')
    local Cleanup = require('weread.ui.book_cache_cleanup')
    local page_current = require('weread.ui.page_scope').capture(self, detail, '_book_detail_view')
    local query, menu, visible = '', nil, nil
    local hold_hint = _('Hold a separately downloaded chapter to remove its copy')
    local function current()
        return menu and self._saved_chapter_menu == menu and not menu._shelf_closed and page_current()
    end
    local function items()
        local matches, counts = ChapterSearch.filter(rows, query)
        local entries = {}
        visible = {}
        for index=1,(matches and #matches or #rows) do
            local row = rows[matches and matches[index] or index]
            local text = ChapterSearch.label(row.title, row.position, counts)
            local entry = { text = text }
            visible[entry] = row
            entries[index] = entry
        end
        if matches and #matches==0 then entries[1]={text=_('No matching chapters.'),select_enabled=false} end
        return entries
    end
    menu = self:showList(_('Downloaded chapters'), items(), _('No downloaded chapters found.'), {
        left_icon='appbar.search', subtitle=hold_hint, on_choice=function(entry)
            local chapter = visible[entry]
            if not current() or not chapter then return end
            local fresh = ReadAccess.load_cached_book(self.settings, book_id)
            if not fresh then self:showInfo(_('No downloaded chapters found.')); return end
            if self:openChapter(fresh, chapter, nil, { cached_only = true }) and self._saved_chapter_menu == menu then
                UIManager:close(menu)
            end
        end,
    })
    if not menu then return end
    self._saved_chapter_menu = menu
    menu.onMenuHold = function(_menu, entry)
        local chapter = visible[entry]
        if not current() or not chapter then return true end
        local path = ReadAccess.cached_chapter(latest.cached_chapters, chapter.chapterUid)
        if not path or not file_exists(path) then
            self:showInfo(_('No separate chapter download could be verified.'))
            return true
        end
        Cleanup.show(self, {book_id}, entry.text, function()
            local fresh = ReadAccess.load_cached_book(self.settings, book_id)
            UIManager:close(menu)
            UIManager:close(detail)
            if fresh then self:showBookMenu(fresh) end
        end, {path=path, chapter_uid=chapter.chapterUid})
        return true
    end
    menu.onLeftButtonTap = function()
        ChapterSearch.prompt(self, menu, query, current, function(value)
            query = value
            menu.subtitle = query~='' and T(_('Chapter filter: %1'), query) or hold_hint
            menu:switchItemTable(nil, items(), nil, nil, menu.subtitle)
        end)
        return true
    end
    local on_close = menu.onCloseWidget
    menu.onCloseWidget = function(widget,...)
        if self._saved_chapter_menu == widget then self._saved_chapter_menu = nil end
        local cleanup = self.book_cache_cleanup_job
        if cleanup and cleanup.owner.saved_chapters == widget then Cleanup.cancel(self) end
        widget._shelf_closed = true
        Popup.close(widget)
        if on_close then return on_close(widget,...) end
    end
end

function M:showChapterList(book, on_close)
    local ChapterListView = require("weread.ui.chapter_list_view")
    local ChapterSearch = require("weread.ui.chapter_search")
    local Popup = require("weread.ui.shelf_popup")
    local search = ""
    local function reloadBookCache()
        if not self.settings then return end
        local book_id = book.book_id or book.bookId
        local latest = book_id and ReadAccess.load_cached_book(self.settings,book_id)
        if type(latest) ~= "table" then return end
        for field in pairs(local_cache_fields) do
            if latest[field] ~= nil then book[field] = latest[field] end
        end
        if self.library_db then self.library_db:putBook(latest) end
    end
    local showCatalog
    showCatalog = function(chapters, old_view, rows)
        if old_view and (self._chapter_list_view ~= old_view or old_view._catalog_closed) then return end
        if not rows then
            -- Downloads persist their cache paths before invoking on_complete.
            reloadBookCache()
            rows = {}
            local is_cached = chapter_cache_lookup(self, book)
            for _index, chapter in ipairs(chapters) do
                local chapter_uid = chapter.chapterUid or chapter.chapterId
                rows[#rows + 1] = {
                    title = chapter.title or T(_("Chapter %1"), tostring(chapter_uid)),
                    status = is_cached(chapter_uid) and _("Cached")
                        or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                    source = chapter,
                }
            end
        end
        local matches, counts = ChapterSearch.filter(rows, search)
        local visible = rows
        if matches then
            visible = {}
            for _, index in ipairs(matches) do
                local row = rows[index]
                local title = ChapterSearch.label(row.title, index, counts)
                visible[#visible + 1] = title == row.title and row or { title = title, status = row.status, source = row.source }
            end
        end
        if old_view then
            UIManager:close(old_view)
        end
        local view
        view = ChapterListView.show({
            title = book.title or _("Chapter list"),
            chapters = visible,
            subtitle = counts and T(_("Chapter filter: %1"), search) or nil,
            empty_text = #visible == 0 and _(counts and "No matching chapters." or "No chapters.") or nil,
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
            on_search = self:safeCallback(_("Find chapter"), function()
                ChapterSearch.prompt(self, view, search, function()
                    return self._chapter_list_view == view and not view._catalog_closed
                end, function(query)
                    search = query
                    showCatalog(chapters, view, rows)
                end)
            end),
            on_select = function(chapter)
                if self._chapter_list_view ~= view or view._catalog_closed then return end
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
                require('weread.ui.catalog_request').cancel(self,view)
                if self._chapter_list_view ~= view then return end
                self._chapter_list_view = nil
                if on_close then on_close() end
            end,
        })
        self._chapter_list_view = view
        local on_close_widget=view.onCloseWidget
        view.onCloseWidget=function(widget,...)
            widget._catalog_closed=true
            widget._shelf_closed=true
            Popup.close(widget)
            require('weread.ui.catalog_request').cancel(self,widget)
            require('weread.ui.download_recovery').cancel(self,false,widget)
            if on_close_widget then return on_close_widget(widget,...) end
        end
    end
    self:loadChapters(book, function(chapters)
        showCatalog(chapters)
    end)
end

function M:showChapterDownloadSelection(book, chapters, on_downloaded)
    local ChapterSearch = require("weread.ui.chapter_search")
    local Popup = require("weread.ui.shelf_popup")
    local selected = {}
    local menu, current_items
    local search = ""
    local chapter_view=self._chapter_list_view
    local page_current=require('weread.ui.page_scope').capture(self,self.shelf_view)
    local function current()
        return menu and not menu._weread_closed and page_current()
            and (not chapter_view or self._chapter_list_view == chapter_view and not chapter_view._catalog_closed)
    end
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

    local is_chapter_cached=chapter_cache_lookup(self,book)
    local perpage = list_items_per_page()
    local chapters_per_page = math.max(1, perpage - 1)
    local rows = {}
    for index, chapter in ipairs(chapters) do
        local uid = tostring(chapter.chapterUid or chapter.chapterId or index)
        rows[index] = { uid = uid, title = chapter.title or T(_("Chapter %1"), uid) }
    end
    local download = self:safeCallback(_("Download selected chapters"), function()
        if not current() then return end
        local targets = selectedChapters()
        if #targets == 0 then return end
        self:confirmAndDownloadChapters(book, targets, "chapters", {
            separate_chapters = true,
            recovery_owner = menu,
            recovery_parent_owner = chapter_view,
            recovery_current = current,
            on_complete = function(ok)
                if not ok then return end
                UIManager:scheduleIn(0.1, function()
                    if not current() then return end
                    UIManager:close(menu)
                    if on_downloaded then on_downloaded() end
                end)
            end,
        })
    end)
    local function buildItems()
        local matches, counts = ChapterSearch.filter(rows, search)
        local items = {}
        current_items = items
        local function appendDownloadAction()
            items[#items + 1] = {
                text_func = function()
                    return T(_("[Download] Selected chapters (%1)"), tostring(selectedCount()))
                end,
                bold = true,
                select_enabled_func = function() return selectedCount() > 0 end,
                separator = true,
                callback = download,
            }
        end
        for number = 1, (matches and #matches or #rows) do
            if (number - 1) % chapters_per_page == 0 then appendDownloadAction() end
            local chapter_index = matches and matches[number] or number
            local chapter = chapters[chapter_index]
            local row = rows[chapter_index]
            local uid = row.uid
            local label = ChapterSearch.label(row.title, chapter_index, counts)
            items[#items + 1] = {
                text_func = function()
                    local marker = selected[uid] and "[✓] " or "[  ] "
                    return marker .. label
                end,
                mandatory_func = function()
                    if selected[uid] then return _("Selected") end
                    if row.cached == nil then row.cached = is_chapter_cached(uid) end
                    return row.cached and _("Cached")
                        or T(_("%1 words"), tostring(chapter.wordCount or 0))
                end,
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if items ~= current_items or not current() then return end
                    selected[uid] = not selected[uid] or nil
                    menu:updateItems()
                end),
            }
        end
        if matches and #matches == 0 then
            appendDownloadAction()
            items[#items + 1] = { text = _("No matching chapters."), select_enabled = false }
        end
        return items
    end
    menu = self:showList(_("Select chapters to download"), buildItems(),
        _("No chapters."), { items_per_page = perpage, left_icon = "appbar.search", subtitle = "" })
    if menu then
        menu.onLeftButtonTap = function()
            ChapterSearch.prompt(self, menu, search, current, function(query)
                search = query
                menu.subtitle = search ~= "" and T(_("Chapter filter: %1"), search) or ""
                menu:switchItemTable(nil, buildItems(), nil, nil, menu.subtitle)
            end)
            return true
        end
        local on_close_widget=menu.onCloseWidget
        menu.onCloseWidget=function(widget,...)
            widget._weread_closed=true
            Popup.close(widget)
            require('weread.ui.download_recovery').cancel(self,false,widget)
            if on_close_widget then return on_close_widget(widget,...) end
        end
    end
end

function M:openFile(path, after_open_callback, resume_book)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    if self._read_resume_token then require('weread.ui.read_resume').cancel(self) end
    local function dispatch(callback)
        self:closeWeReadUI()
        if self.ui.document then self.ui:switchDocument(path,nil,callback)
        else self.ui:openFile(path,nil,nil,nil,callback) end
    end
    if resume_book and not after_open_callback then return require('weread.ui.read_resume').open(self,path,resume_book,dispatch) end
    return dispatch(after_open_callback)
end

function M:openCachedBook(book)
    self:openFile(self:getFullBookCachePath(book),nil,book)
end

-- Read offline from the best available cache. A complete EPUB wins. Otherwise
-- choose the cached chapter nearest to the last known chapter/progress, with a
-- slight preference for the preceding chapter when distances are equal.
function M:openBookForReading(book, quiet, options)
    local full_path = self:getFullBookCachePath(book)
    local book_id = book.book_id or book.bookId
    local claims=require('weread.lib.chapter_cache_claim')
    local Reading=require('weread.ui.book_reading')
    local claim_cache={}
    local unusable_shared=false
    local function usable(uid,path)
        if not file_exists(path) then return false end
        local valid=claims.usable(book,path,uid,claim_cache)
        if not valid and claims.shared(book,path,claim_cache) then unusable_shared=true end
        return valid
    end
    local cloud_hint=type(book_id)=='string' and book_id:sub(1,3)=='CB_' and book.cb_cloud_view_resume
    local hint=cloud_hint or book.unindexed_resume
    local account=self.library_db and self.library_db.accountKey and self.library_db:accountKey()
    if account==nil and self.progress_sync and self.progress_sync._account_key then account=self.progress_sync:_account_key() end
    local Hint=require('weread.lib.unindexed_resume')
    if cloud_hint and (not self.settings or not Hint.valid(cloud_hint,tostring(book_id),account,self.settings:get('auth_epoch',0))) then
        cloud_hint=nil;hint=book.unindexed_resume
    end
    local hint_valid=not (options and options.skip_unindexed_resume) and hint and self.settings
        and Hint.valid(hint,tostring(book_id),account,self.settings:get('auth_epoch',0))
    if hint_valid then
        local chapters=book.chapters
        if type(chapters)~='table' or #chapters==0 then
            chapters=self.library_db and self.library_db:getChapters(book_id)
        end
        if type(chapters)~='table' or #chapters==0 then
            chapters=Content.load_catalog_cache(self.client,self.settings,book)
        end
        if cloud_hint or type(chapters)~='table' or #chapters==0 then
            local mapped=ReadAccess.cached_chapter(book.cached_chapters,hint.chapter_uid)
            local paths={}
            if file_exists(mapped) then paths[#paths+1]=mapped end
            if full_path~=mapped and file_exists(full_path) then paths[#paths+1]=full_path end
            if #paths>0 then
                if options and options.check_only then return true end
                if require('weread.ui.unindexed_resume').start(self,book,hint,paths,{cloud_view=cloud_hint~=nil}) then return true end
                self:showInfo(_('Could not verify the saved chapter. Search downloaded chapters again or choose another chapter.'))
                return true
            end
            if options and options.prefer_exact then return false,'resume_not_cached',hint.chapter_uid end
        end
    end
    if file_exists(full_path) then
        if options and options.prefer_exact and claims.inspect(book,full_path,claim_cache).kind=='combined' then
            local catalog=book.chapters
            if (type(catalog)~='table' or #catalog==0) and self.library_db then catalog=self.library_db:getChapters(book_id) end
            if type(catalog)~='table' or #catalog==0 then catalog=Content.load_catalog_cache(self.client,self.settings,book) end
            local uid=Reading.resume_uid(catalog,book,account)
            if uid and not claims.usable(book,full_path,uid,claim_cache) then return false,'resume_not_cached',uid end
        end
        if not (options and options.check_only) then self:openFile(full_path,nil,book) end
        return true
    end

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
    if options and options.prefer_exact then
        local uid=Reading.resume_uid(chapters,book,account)
        local target=uid and ReadAccess.cached_chapter(book.cached_chapters,uid)
        if uid and not usable(uid,target) then
            for _id,path in pairs(book.cached_chapters or {}) do
                if usable(_id,path) then return false,'resume_not_cached',uid end
            end
            if file_exists(target) and claims.shared(book,target,claim_cache) then return false,'ambiguous_cache',uid end
        end
    end
    if type(chapters) == "table" then
        target_index=Reading.resume_index(chapters,book,nil,account)
        for index, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId or index)
            local path = ReadAccess.cached_chapter(book.cached_chapters,uid)
            if usable(uid,path) then
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
        if not (options and options.check_only) then self:openFile(candidates[1].path,nil,book) end
        return true
    end

    local fallback_paths = {}
    for uid, path in pairs(book.cached_chapters or {}) do
        if usable(uid,path) then fallback_paths[#fallback_paths + 1] = { uid = tostring(uid), chapterUid=tostring(uid), path = path } end
    end
    table.sort(fallback_paths, function(left, right) return left.uid < right.uid end)
    local fallback=fallback_paths[Reading.resume_index(fallback_paths,book,nil,account) or 1]
    if fallback then
        if not (options and options.check_only) then self:openFile(fallback.path,nil,book) end
        return true
    end
    if not quiet then self:showInfo(_(unusable_shared
        and 'No verifiable cached chapter is available. The old files and notes are kept. Download the chapter again.'
        or 'No cached file.')) end
    if unusable_shared then return false,'ambiguous_cache' end
    return false
end

function M:readCachedCopy(book,view)
    if view and self._book_detail_view~=view then return false end
    local id=book.book_id or book.bookId
    local latest=self.settings:get_book(id) or book
    local opened,reason,uid=self:openBookForReading(latest,true,{prefer_exact=true})
    if opened then return true end
    if reason=='resume_not_cached' then return require('weread.ui.missing_resume').show(self,id,view,uid) end
    if reason=='ambiguous_cache' then self:showInfo(_('No verifiable cached chapter is available. The old files and notes are kept. Download the chapter again.'));return false end
    self:showInfo(_('No cached file.'))
    return false
end

function M:readFromBookList(book, view, current, cached_only, native_cached)
    if self.shelf_view ~= view or not current() then return false end
    local id = ShelfSnapshot.persisted_id(book)
    if not id then return false end
    local record, conflict = ReadAccess.load_cached_book(self.settings, id)
    if conflict then
        self:showInfo(_('Saved book information does not match. Check the local cache before opening.'))
        return false
    end
    local resume = record and record.native_home_resume and require('weread.ui.native_home_resume')
    if resume and resume.can_resume(self, record, id) then return resume.open(self, record, id, view, current) end
    local cached = self:bookRecordHasDownload(record)
    if not cached and (cached_only and native_cached or self:nativeChapterCachePresent(id)) then
        local detail = self:showBookMenu(book,{read_saved_native=cached_only==true})
        return detail and require('weread.ui.native_direct_reading').start(self, book, detail, {cached=true}) or false
    end
    if not cached_only then return self:startBookReading(book, nil, {current=current}) end
    if cached then return self:readCachedCopy(record) end
    self:showInfo(_('No cached file.'))
    return false
end

function M:startBookReading(book, view, origin)
    if view and self._book_detail_view ~= view then return false end
    if origin and not origin.current() then return false end
    local warning=package.loaded['weread.ui.missing_resume']
    if warning then warning.cancel(self) end
    local id = book.book_id or book.bookId
    local latest = self.settings:get_book(id) or book
    local online
    if self.isNetworkConnected then online=self:isNetworkConnected()
    elseif self.isNetworkOnline then online=self:isNetworkOnline() end
    local exact=online and require('weread.lib.shelf_source').web_access(self.settings)~=nil
    local opened,reason,uid=self:openBookForReading(latest,true,{prefer_exact=true})
    if opened then return true end
    if reason=='resume_not_cached' and not exact then
        return require('weread.ui.missing_resume').show(self,id,view,uid)
    end
    if reason=='ambiguous_cache' and not exact then
        self:showInfo(_('No verifiable cached chapter is available. The old files and notes are kept. Download the chapter again.'));return false
    end
    return require("weread.ui.book_reading").start(self, latest, view, origin)
end

function M:cancelBookReading()
    local unindexed=package.loaded['weread.ui.unindexed_resume']
    if unindexed then unindexed.cancel(self) end
    local warning=package.loaded['weread.ui.missing_resume']
    if warning then warning.cancel(self) end
    return require("weread.ui.book_reading").cancel(self)
end

-- Open a chapter, preferring its cached file and falling back to a download.
function M:openChapter(book, chapter, on_downloaded, options)
    require('weread.ui.prefetch_auth_recovery').cancel(self)
    local intent={};self._chapter_open_intent=intent
    local document=self.ui and self.ui.document
    local session=self._reader_session_gen
    local view=self._chapter_list_view
    local scope=self.settings.get_auth_scope and self.settings:get_auth_scope()
    local sync=self.progress_sync
    local navigation=sync and sync.navigation_generation
    local Context=require('weread.lib.source_context')
    local location=document and Context.location(document,self.ui.view and self.ui.view.view_mode)
    local book_id=tostring(book.book_id or book.bookId or '')
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local chapter_id=tostring(chapter_uid or '')
    local function current()
        if self._chapter_open_intent~=intent or (self.ui and self.ui.document)~=document
            or self._reader_session_gen~=session or self.progress_sync~=sync
            or sync and sync.navigation_generation~=navigation
            or view and (self._chapter_list_view~=view or view._catalog_closed)
            or tostring(book.book_id or book.bookId or '')~=book_id
            or tostring(chapter.chapterUid or chapter.chapterId or '')~=chapter_id then return false end
        if scope and not self.settings:auth_scope_matches(scope) then return false end
        if document and not Context.same_location(location,Context.location(document,self.ui.view and self.ui.view.view_mode)) then return false end
        return true
    end
    local cached = ReadAccess.cached_chapter(book.cached_chapters,chapter_uid)
    local claims=require('weread.lib.chapter_cache_claim')
    local cached_exists=cached and file_exists(cached)
    local full=self:getFullBookCachePath(book)
    local combined,proof
    local claim_cache={}
    local cached_only=options and options.cached_only
    if full and file_exists(full) and document and document.file==full then
        local info=claims.combined(book,full)
        if info and info.items['chapter_'..chapter_id] then combined,proof=full,info end
    end
    if not combined and cached_exists then
        local info=claims.inspect(book,cached,claim_cache,cached_only)
        if info.kind=='combined' and info.items['chapter_'..chapter_id] then combined,proof=cached,info end
    end
    local ambiguous=not combined and cached_exists and not claims.usable(book,cached,chapter_uid,claim_cache,cached_only)
    if not combined and (not cached_exists or ambiguous) and full and file_exists(full) then
        local info=claims.combined(book,full)
        if info and info.items['chapter_'..chapter_id] then combined,proof=full,info end
    end
    if combined then
        local catalog=book.chapters
        if (type(catalog)~='table' or #catalog==0) and self.library_db then catalog=self.library_db:getChapters(book_id) end
        if type(catalog)~='table' or #catalog==0 then catalog=Content.load_catalog_cache(self.client,self.settings,book) end
        return require('weread.ui.combined_chapter_navigation').open(self,book,chapter,combined,current,proof,
            not claims.complete(proof,catalog) or not proof.file_id)
    end
    if cached_exists and not ambiguous then
        self:openFile(cached,nil,book)
        return true
    elseif cached_only then
        self:showInfo(_('The downloaded chapter is unavailable or could not be verified.'))
        return false
    elseif ambiguous then
        self:confirmAndDownloadChapters(book,{chapter},'chapter',{
            single_chapter=true,recovery_current=current,
            confirmation_text=_('This cached file cannot be confirmed as the selected chapter. Download it again? The old file and notes are kept.'),
            on_complete=function(ok,path) if ok and on_downloaded then on_downloaded(path) end end,
        })
    elseif self.downloader:promotePrefetch(book, chapter, current) then
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
    local cached = chapter_uid and ReadAccess.cached_chapter(book.cached_chapters,chapter_uid)
    local ambiguous=cached and file_exists(cached) and not require('weread.lib.chapter_cache_claim').usable(book,cached,chapter_uid)
    if cached and file_exists(cached) and not ambiguous then
        return open_target(cached)
    end

    local title = chapter.title
        or T(_("Chapter %1"), tostring(chapter_uid or ""))
    local confirm
    confirm = ConfirmBox:new{
        text = ambiguous and T(_('The cached file cannot be confirmed as "%1". Download it again and open the cloud position? The old file and notes are kept.'),title) or T(_(
            "Cloud progress is in \"%1\", but this chapter has not been downloaded.\n\n"
            .. "Download and open it now?"
        ), title),
        ok_text = _("Download target chapter"),
        ok_callback = self:safeCallback(_("Download target chapter"), function()
            UIManager:close(confirm)
            if not current() then return end
            require('weread.ui.download_recovery').start(self,book, { chapter }, "chapter", {
                single_chapter = true,
                silent_completion = true,
                offer_read = false,
                recovery_current = current,
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
    require('weread.ui.prefetch_auth_recovery').cancel(self)
    options = options or {}
    local reader_context=require('weread.lib.reader_context')
    local valid_id,id=pcall(reader_context.book_id,book)
    if not valid_id then return end
    local page_current=require('weread.ui.page_scope').capture(self,self.shelf_view)
    local chapter_view=(options.single_chapter or options.separate_chapters) and self._chapter_list_view or nil
    local previous_current=options.recovery_current
    local guarded={};for key,value in pairs(options) do guarded[key]=value end
    guarded.recovery_owner=options.recovery_owner or chapter_view
    guarded.recovery_current=function()
        local valid,current_id=pcall(reader_context.book_id,book)
        if not valid or current_id~=id or not page_current() then return false end
        if chapter_view and (self._chapter_list_view~=chapter_view or chapter_view._catalog_closed) then return false end
        if previous_current then local ok,result=pcall(previous_current);return ok and result==true end
        return true
    end
    local text = options.confirmation_text
        or T(_("Download %1 selected chapter(s)?"), tostring(#chapters))
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Download"), cancel_text = _("Cancel"),
        ok_callback = self:safeCallback(_("Download"), function()
            if guarded.recovery_current() then
                require('weread.ui.download_recovery').start(self,book,chapters,suffix,guarded)
            end
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
    -- Use the same cancellable, native-first search as the bookstore. Keep the
    -- reader's background work alive when there is no existing WeRead view.
    if self.shelf_view or self._book_detail_view or self._profile_view or self._chapter_list_view
        or self._read_stats_view or self._mp_article_list_view or self._discovery_menu then
        self:closeWeReadUI()
    end
    self:showBookstore()
    self:showDiscoverySearch()
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

function M:showMyCloudMarks(book_id)
    return require('weread.ui.my_cloud_marks').show(self,book_id)
end

function M:showMyCloudThoughts(book_id)
    return require('weread.ui.my_cloud_marks').show(self,book_id,'thoughts')
end
function M:showMyCloudBookmarks(book_id)
    return require('weread.ui.my_cloud_marks').show(self,book_id,'bookmarks')
end

function M:cancelMyCloudMarks()
    return require('weread.ui.my_cloud_marks').cancel(self)
end

function M:cancelBookSearch()
    local search=package.loaded['weread.ui.book_search']
    if search then search.cancel(self) end
    local cached=package.loaded['weread.ui.cached_book_search']
    if cached then cached.cancel(self) end
    local direct=package.loaded['weread.ui.native_direct_search']
    if direct then direct.cancel(self) end
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
