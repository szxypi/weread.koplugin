-- MiuRead-style home and discovery flow on the existing WeRead service layer.
local Data = require("weread.lib.discovery_data")
local PluginUtil = require("weread.lib.plugin_util")
local UIManager = require("ui/uimanager")
local Scope = require("weread.ui.page_scope")
local Popup = require("weread.ui.shelf_popup")
local ReadAccess = require("weread.lib.read_access")
local ShelfSnapshot = require("weread.lib.shelf_snapshot")
local VolatileShelf = require("weread.lib.volatile_shelf")
local _ = PluginUtil.tr
local M = {}

function M:discoveryNavigation(active, current)
    local function switch(callback)
        return function()
            if current and not current() then return end
            self:closeWeReadUI()
            callback()
        end
    end
    return {
        { text = _("Home"), active = active == "home",
            callback = switch(function() self:showHome() end) },
        { text = _("Bookshelf"), active = active == "shelf",
            callback = switch(function() self:showBookshelf() end) },
        { text = _("Bookstore"), active = active == "store",
            callback = switch(function() self:openBookstore() end) },
        { text = _("My WeRead"), active = active == "profile",
            callback = switch(function() self:showProfile() end) },
    }
end

function M:showDiscoveryPage(tab, books, options)
    local LibraryView = require("weread.ui.library_view")
    options = options or {}
    local previous=self.shelf_view
    local carry_dirty
    if previous and previous._finish_dirty and previous._finish_current and previous._finish_current()
        and not require('weread.ui.finish_offline').reconcile_view(self,previous) then carry_dirty=previous._finish_dirty end
    local home = options.home
    local show_reason=false
    if tab=='store' then for _,book in ipairs(books) do
        if type(book.reason)=='string' and book.reason~='' then show_reason=true;break end
    end end
    local cover_mode = not home or home.view_mode ~= "list"
    local layout = LibraryView.getLayout(cover_mode, #books, "books", 108, { home = home, store = tab=='store' })
    local page = math.max(1, math.min(options.page or 1, math.max(1, math.ceil(#books / layout.page_size))))
    local cover_paths, visible = {}, {}
    local cache = self:getShelfCoverCache()
    local saved, downloaded = self.settings:get("books", {}), {}
    for index = (page - 1) * layout.page_size + 1, math.min(#books, page * layout.page_size) do
        local book = books[index]
        cover_paths[book] = cache:pathFor(book)
        book._cached = self:isBookDownloaded(book, saved, downloaded)
        visible[#visible + 1] = book
    end
    local snapshots = tab == "home" and self.prepareShelfProgress and self:prepareShelfProgress(visible)
    self:cancelShelfCovers()
    if self.stopHomeStatusTimer then self:stopHomeStatusTimer() end
    if self.shelf_view then UIManager:close(self.shelf_view) end
    local view, scope
    local function current() return scope and scope() end
    local function redraw(next_page)
        if not current() then return end
        options.page = next_page
        Popup.redraw(view, function()
            if current() and not self._book_detail_view then self:showDiscoveryPage(tab, books, options) end
        end)
    end
    view = LibraryView.show({
        mode = "books", portal = true, title = options.title,
        empty_text = options.empty_text, actions = Scope.entries(current, options.actions),
        home_layout = home,
        store_details = tab=='store', store_reason = show_reason,
        status_text = home and self:homeStatusText(),
        summary_text = home and self:homeReadingSummary(),
        navigation = self:discoveryNavigation(tab, current), books = books,
        finish_pending = require('weread.ui.finish_offline').snapshot(self),
        cover_mode = cover_mode, paged = true, page = page,
        page_size = layout.page_size, cover_columns = layout.columns,
        cover_rows = layout.rows, cover_paths = cover_paths,
    }, {
        on_search = Scope.guard(current, function() self:showDiscoverySearch() end),
        on_refresh = Scope.guard(current, options.on_refresh),
        on_settings = home and Scope.guard(current, function() self:showHomeQuickSettings() end) or nil,
        on_summary = home and Scope.guard(current, function() self:closeWeReadUI() self:showProfile() end) or nil,
        on_select = Scope.guard(current, function(book)
            if tab == "home" then
                local saved_books=self.settings:get("books", {})
                local id=ShelfSnapshot.persisted_id(book)
                local stored=id and ReadAccess.cached_book(saved_books,id)
                local resume=stored and stored.native_home_resume and require('weread.ui.native_home_resume')
                if resume then
                    if resume.can_resume(self,stored,id) then resume.open(self,stored,id,view,current)
                    else self:showBookRecord(book) end
                elseif stored and book._cached and self:bookRecordHasDownload(stored) then self:startBookReading(stored)
                else self:showBookRecord(book) end
            else self:showBookRecord(book) end
        end),
        on_hold = Scope.guard(current, function(book)
            require('weread.ui.book_quick_actions').open(self, view, book, current)
        end),
        on_page_changed = redraw,
        on_close = function()
            if self.shelf_view == view then
                self.shelf_view = nil
                self:closeWeReadUI()
            end
        end,
    })
    self.shelf_view = view
    view._finish_dirty=carry_dirty
    view._discovery_tab = tab
    scope = Scope.capture(self, view)
    view._discovery_current = current
    view._finish_current = current
    view._shelf_snapshot_redraw = function()
        local updated=books
        if home then
            local prefs=self:homePreferences()
            updated=Data.recent(self.shelf_regular,self.settings:get('books',{}),
                self.library_db and self.library_db:accountKey(),prefs.recent_limit)
        end
        require('weread.ui.finish_offline').redraw_preserving_focus(self,view,function()
            options.page=view.page;self:showDiscoveryPage(tab,updated,options)
        end)
    end
    view._finish_redraw = function()
        if not current() then return end
        require('weread.ui.finish_offline').redraw_preserving_focus(self,view,function()
            options.page=view.page;self:showDiscoveryPage(tab,books,options)
        end)
    end
    view._prepare_detail_return = function(snapshot_current)
        if not current() then
            if snapshot_current then return function()
                if self.shelf_view==view and not view._shelf_closed then view._shelf_snapshot_redraw() end
            end end
            return
        end
        require('weread.ui.finish_offline').reconcile_view(self,view)
        return function()
            if self.shelf_view == view and not view._shelf_closed then
                options.page = view.page
                self:showDiscoveryPage(tab, books, options)
            end
        end
    end
    if home and self.startHomeStatusTimer then self:startHomeStatusTimer(view, false) end
    if snapshots then
        local force = options.refresh_progress
        options.refresh_progress = nil
        self:refreshVisibleShelfProgress(view, visible, snapshots, {
            force = force, on_redraw = function()
                Popup.redrawForMetadata(self,view,function() redraw(view.page or page) end)
            end,
        })
    elseif self.cancelShelfProgress then self:cancelShelfProgress() end
    if cover_mode then self:fetchVisibleShelfCovers(view, books, { on_redraw = redraw }) end
end

function M:recordRecentReading(book_id)
    -- Keep the legacy field untouched: older local and pending positions may
    -- still depend on it for their account identity.
    return self.settings:patch_reading_state(book_id, {
        home_recent_at = os.time(), home_recent_account = self.library_db:accountKey() or '', native_home_resume=false,
    })
end

function M:showHome(refresh_progress, refreshed_shelf)
    if self._profile_view then self:closeWeReadUI() end
    local cached, archives
    local volatile = VolatileShelf.get(self)
    if type(refreshed_shelf) == "table" and type(refreshed_shelf.books) == "table"
        and type(refreshed_shelf.archives) == "table" then
        cached, archives = refreshed_shelf.books, refreshed_shelf.archives
    elseif volatile then
        cached, archives = volatile.books, volatile.archives
    else
        cached = self.library_db and self.library_db:getShelf() or {}
        archives = self.library_db and self.library_db:getShelfArchives() or {}
    end
    self:applyShelfSnapshot(cached or {}, archives,
        volatile ~= nil and volatile.books == cached and volatile.archives == archives)
    local preferences = self:homePreferences()
    self:showDiscoveryPage("home", Data.recent(self.shelf_regular, self.settings:get("books", {}),
        self.library_db and self.library_db:accountKey(), preferences.recent_limit), {
        title = _("WeRead home"),
        home = preferences,
        refresh_progress = refresh_progress,
        empty_text = _("No recent reading. Refresh or open your bookshelf."),
        actions = self:homeShortcuts(preferences),
        on_refresh = function() self:refreshHome() end,
    })
end

function M:refreshHome()
    self:refreshBookshelf(self.shelf_view, { on_loaded = function(saved, snapshot, groups_incomplete)
        self:showHome(true, snapshot)
        if groups_incomplete and not saved then
            self:showTransientInfo(_("The bookshelf did not include group information. This temporary list is not saved; refresh again later."), 5)
        elseif not saved then
            self:showTransientInfo(_("Could not save the bookshelf for offline use. The current list is still available."), 4)
        end
    end })
end

function M:showDiscoverySearch(initial_keyword)
    local InputDialog = require("ui/widget/inputdialog")
    local owner = self.shelf_view
    if not owner or owner._shelf_closed then return end
    local current = Scope.capture(self, owner)
    if not current() then return end
    local state=self.discovery_state
    local account=self.library_db and self.library_db:accountKey()
    if initial_keyword==nil and account and owner._discovery_tab=='store' and state and state.kind=='search'
        and state.account==account then initial_keyword=state.keyword end
    if type(initial_keyword)~='string' or #initial_keyword>4096 or initial_keyword:find('[%z%c]')
        or require('weread.lib.protocol').utf8_substr(initial_keyword,#initial_keyword+1)~=initial_keyword then
        initial_keyword=''
    end
    local dialog
    local function valid() return current() and Popup.current(owner, dialog) end
    dialog = InputDialog:new{
        title = _("Search WeRead"), input = initial_keyword, input_type = "text",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() if valid() then Popup.close(owner) end end },
            { text = _("Search"), is_enter_default = true, callback = function()
                if not valid() then return end
                local keyword = require("weread.lib.search_query").trim(dialog:getInputText())
                if keyword == "" then return end
                Popup.close(owner)
                self:loadDiscoveryBatch("search", keyword, 0)
            end },
            { text = _("Saved searches"), callback = function()
                if not valid() then return end
                -- Keep the input owned by the page while the worker runs so
                -- background redraws wait until the replacement menu closes.
                require("weread.ui.saved_searches").open(self, dialog)
            end },
        },{
            { text = _("Search suggestions"), callback = function()
                if valid() then require("weread.ui.search_suggestions").open(self, dialog) end
            end },
            { text = _("Public book search"), callback = function()
                if not valid() then return end
                local keyword=require('weread.lib.search_query').trim(dialog:getInputText())
                if keyword=='' then return end
                Popup.close(owner)
                self:loadDiscoveryBatch('search',keyword,0,false,false,{public_search=true})
            end },
        },{
            { text = _("Recent searches"), callback = function()
                if valid() then require("weread.ui.recent_searches").open(self, dialog) end
            end },
        }},
    }
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        require("weread.ui.search_suggestions").cancel(self)
        if on_close then return on_close(widget,...) end
    end
    Popup.show(owner, dialog, function(widget) self:showInputDialog(widget) end)
end

function M:showSimilarBooks(book)
    local id = book and (book.bookId or book.book_id)
    if not id or tostring(id) == "" then return end
    self:loadDiscoveryBatch("similar", nil, 0, false, false, {
        book_id = tostring(id), book_title = book.title or tostring(id),
    })
end

function M:showDiscoveryCategoryPicker(data)
    local menu
    local owner = self.shelf_view
    local scope = Scope.capture(self, owner)
    local function current()
        return self._discovery_menu==menu and scope() and (not owner or Popup.current(owner, menu))
    end
    local function dismiss()
        if self._discovery_menu == menu then self._discovery_menu = nil end
        if owner then Popup.close(owner) elseif menu then UIManager:close(menu) end
    end
    local function rows(entries)
        local items = {}
        for _i, entry in ipairs(entries) do
            local function browse()
                if not current() then return end
                dismiss()
                self:loadDiscoveryBatch("category", nil, 0, false, false, {
                    category_id = entry.id, category_title = entry.title, rank = entry.rank,
                })
            end
            local item = { text = entry.title, callback = browse }
            if #entry.children > 0 then
                item.sub_item_table = rows(entry.children)
                table.insert(item.sub_item_table, 1, {
                    text = PluginUtil.T(_("All in %1"), entry.title), callback = browse,
                })
            end
            items[#items + 1] = item
        end
        if #items == 0 then items[1] = { text = _("No available categories."), select_enabled = false } end
        return items
    end
    local old_menu=self._discovery_menu;self._discovery_menu=nil
    if old_menu then UIManager:close(old_menu) end
    local title = _("Rankings and categories")
    local age=os.time()-data.loaded_at
    if age<0 or age>Data.CACHE_TTL then title = _("Cached") .. " · " .. title end
    menu = self:showList(title, {
        { text = _("Book rankings"), sub_item_table = rows(data.ranks) },
        { text = _("Browse categories"), sub_item_table = rows(data.categories) },
        { text = _("Refresh rankings and categories"), callback = function()
            if not current() then return end
            dismiss()
            self:showDiscoveryCategories(true)
        end },
    })
    self._discovery_menu = menu
    local function forget()
        if self._discovery_menu == menu then
            self._discovery_menu = nil
            if not owner then self.discovery_epoch = (self.discovery_epoch or 0) + 1 end
        end
    end
    local on_close = menu.onCloseWidget
    menu.onCloseWidget = function(widget, ...)
        forget()
        if on_close then return on_close(widget, ...) end
    end
    menu.close_callback = forget
    if owner then Popup.show(owner, menu, function() end) end
end

function M:showDiscoveryCategories(refresh)
    return require("weread.ui.category_catalog").open(self,refresh)
end

local function initialChart()
    return { category_id = "rising", category_title = _("Rising · Published"), rank = true }
end

-- Load the public chart only on an explicit entry into an otherwise empty
-- store. Redraws and requests that finish later must not restart this work.
function M:openBookstore()
    self:showBookstore()
    local owner = self.shelf_view
    if not owner or self.discovery_state or self.discovery_loading then return end
    local current = owner._discovery_current
    UIManager:nextTick(function()
        if not current or not current() or self.shelf_view ~= owner or self.discovery_state
            or self.discovery_loading or owner._shelf_popup or self.category_catalog_request
            or self.isNetworkConnected and not self:isNetworkConnected() then return end
        self:loadDiscoveryBatch("category", nil, 0, false, false, initialChart())
    end)
end

function M:showBookstore()
    if self._profile_view then self:closeWeReadUI() end
    local state = self.discovery_state
    if state and state.account ~= self.library_db:accountKey() then
        self.discovery_state = nil
        state = nil
    end
    if not state then
        state=require('weread.ui.discovery_cache').read(self)
        self.discovery_state=state
    end
    local actions = {
        { text = _("For you"), callback = function() self:loadDiscoveryBatch("recommend", nil, 0) end },
        { text = _("Search WeRead"), callback = function() self:showDiscoverySearch() end },
        { text = _("Browse books"), callback = function() self:showDiscoveryCategories() end },
    }
    if state and state.has_more then
        actions[#actions + 1] = { text = _("Next batch"), callback = function()
            self:loadDiscoveryBatch(state.kind, state.keyword, state.next_cursor, false, false, state)
        end }
    end
    if state and #state.history > 0 then
        actions[#actions + 1] = { text = _("Previous batch"), callback = function()
            self:loadDiscoveryBatch(state.kind, state.keyword, state.history[#state.history], true, false, state)
        end }
    end
    local title = _("Bookstore")
    if state then
        title = state.kind == "search" and PluginUtil.T(_("Search: %1"), state.keyword) or _("For you")
        if state.kind=='search' and state.source_kind=='public' then title=PluginUtil.T(_("Public search: %1"),state.keyword) end
        if state.kind == "similar" then title = PluginUtil.T(_("Similar to: %1"), state.book_title) end
        if state.kind == "category" then title = state.category_title end
        if state.cached or os.time() - state.loaded_at > Data.CACHE_TTL then title = _("Cached") .. " · " .. title end
    end
    self:showDiscoveryPage("store", state and state.books or {}, {
        title = title, actions = actions,
        empty_text = state and (state.kind == "similar" and _("No similar books found.")
            or state.kind == "search" and _("No search results.") or _("No books found."))
            or _("Choose For you or search to discover books."),
        on_refresh = function()
            self:loadDiscoveryBatch(state and state.kind or "category", state and state.keyword,
                state and state.cursor or 0, false, true, state or initialChart())
        end,
    })
end

function M:cancelDiscoveryRequest()
    require("weread.ui.category_catalog").cancel(self)
    local suggestions=package.loaded['weread.ui.search_suggestions']
    if suggestions then suggestions.cancel(self) end
    return require("weread.ui.discovery_request").cancel(self)
end

function M:loadDiscoveryBatch(kind, keyword, cursor, previous, refresh, context)
    if kind=='search' and cursor==0 and not previous and not refresh then
        pcall(function()
            require('weread.lib.recent_searches').record(self,keyword,type(context)=='table' and context.public_search==true or false)
        end)
    end
    return require("weread.ui.discovery_request").load(self, kind, keyword, cursor, previous, refresh, context)
end

return M
