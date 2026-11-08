-- MiuRead-style home and discovery flow on the existing WeRead service layer.
local Data = require("weread.lib.discovery_data")
local PluginUtil = require("weread.lib.plugin_util")
local UIManager = require("ui/uimanager")
local _ = PluginUtil.tr
local M = {}

function M:discoveryNavigation(active)
    local function switch(callback)
        return function()
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
            callback = switch(function() self:showBookstore() end) },
        { text = _("My WeRead"), active = active == "profile",
            callback = switch(function() self:showProfile() end) },
    }
end

function M:showDiscoveryPage(tab, books, options)
    local LibraryView = require("weread.ui.library_view")
    options = options or {}
    local home = options.home
    local cover_mode = not home or home.view_mode ~= "list"
    local layout = LibraryView.getLayout(cover_mode, #books, "books", 108, { home = home })
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
    self.shelf_cover_generation = (self.shelf_cover_generation or 0) + 1
    if self.stopHomeStatusTimer then self:stopHomeStatusTimer() end
    if self.shelf_view then UIManager:close(self.shelf_view) end
    local function redraw(next_page)
        options.page = next_page
        if home and self.homeControlsOpen and self:homeControlsOpen() then
            self._home_pending_redraw = function() self:showDiscoveryPage(tab, books, options) end
            return
        end
        self:showDiscoveryPage(tab, books, options)
    end
    local view
    view = LibraryView.show({
        mode = "books", portal = true, title = options.title,
        empty_text = options.empty_text, actions = options.actions,
        home_layout = home,
        status_text = home and self:homeStatusText(),
        summary_text = home and self:homeReadingSummary(),
        navigation = self:discoveryNavigation(tab), books = books,
        cover_mode = cover_mode, paged = true, page = page,
        page_size = layout.page_size, cover_columns = layout.columns,
        cover_rows = layout.rows, cover_paths = cover_paths,
    }, {
        on_search = function() self:showDiscoverySearch() end,
        on_refresh = options.on_refresh,
        on_settings = home and function() self:showHomeQuickSettings() end or nil,
        on_summary = home and function() self:closeWeReadUI() self:showProfile() end or nil,
        on_select = function(book)
            if tab == "home" and book._cached then
                local stored = self.settings:get("books", {})[book.bookId or book.book_id] or book
                self:openBookForReading(stored)
            else self:showBookRecord(book) end
        end,
        on_page_changed = redraw,
        on_close = function()
            if self.shelf_view == view then
                self.shelf_view = nil
                self:closeWeReadUI()
            end
        end,
    })
    self.shelf_view = view
    if home and self.startHomeStatusTimer then self:startHomeStatusTimer(view, false) end
    if snapshots then
        local force = options.refresh_progress
        options.refresh_progress = nil
        self:refreshVisibleShelfProgress(view, visible, snapshots, {
            force = force, on_redraw = function() redraw(self.shelf_view and self.shelf_view.page or page) end,
        })
    elseif self.cancelShelfProgress then self:cancelShelfProgress() end
    if cover_mode then self:fetchVisibleShelfCovers(view, books, { on_redraw = redraw }) end
end

function M:recordRecentReading(book_id)
    local books = self.settings:get("books", {})
    local book = books[book_id]
    if not book then return end
    book.recent_read_at = os.time()
    book.recent_read_account = self.library_db:accountKey()
    self.settings:set("books", books)
    self.settings:flush()
end

function M:showHome(refresh_progress)
    if self._profile_view then self:closeWeReadUI() end
    local cached = self.library_db and self.library_db:getShelf() or {}
    local archives = self.library_db and self.library_db:getShelfArchives() or {}
    self:applyShelfSnapshot(cached or {}, archives)
    local preferences = self:homePreferences()
    self:showDiscoveryPage("home", Data.recent(self.shelf_regular, self.settings:get("books", {}),
        self.library_db and self.library_db:accountKey(), preferences.recent_limit), {
        title = _("WeRead home"),
        home = preferences,
        refresh_progress = refresh_progress,
        empty_text = _("No recent reading. Refresh or open your bookshelf."),
        actions = self:homeShortcuts(preferences),
        on_refresh = function()
            self:refreshBookshelf(self.shelf_view, { on_loaded = function() self:showHome(true) end })
        end,
    })
end

function M:showDiscoverySearch()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"), input = "", input_type = "text",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local keyword = dialog:getInputText():match("^%s*(.-)%s*$")
                if keyword == "" then return end
                UIManager:close(dialog)
                self:loadDiscoveryBatch("search", keyword, 0)
            end },
        }},
    }
    self:showInputDialog(dialog)
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
    local account,epoch=self.library_db:accountKey(),self.discovery_epoch or 0
    local function current()
        return self._discovery_menu==menu and account==self.library_db:accountKey() and epoch==(self.discovery_epoch or 0)
    end
    local function dismiss()
        if self._discovery_menu == menu then self._discovery_menu = nil end
        if menu then UIManager:close(menu) end
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
    if age<0 or age>Data.CACHE_TTL then title = title .. " · " .. _("Cached") end
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
    menu.close_callback = function()
        if self._discovery_menu == menu then
            self._discovery_menu = nil
            self.discovery_epoch = (self.discovery_epoch or 0) + 1
        end
    end
end

function M:showDiscoveryCategories(refresh)
    return require("weread.ui.category_catalog").open(self,refresh)
end

function M:showBookstore()
    if self._profile_view then self:closeWeReadUI() end
    local state = self.discovery_state
    if state and state.account ~= self.library_db:accountKey() then
        self.discovery_state = nil
        state = nil
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
        if state.kind == "similar" then title = PluginUtil.T(_("Similar to: %1"), state.book_title) end
        if state.kind == "category" then title = state.category_title end
        if os.time() - state.loaded_at > Data.CACHE_TTL then title = title .. " · " .. _("Cached") end
    end
    self:showDiscoveryPage("store", state and state.books or {}, {
        title = title, actions = actions,
        empty_text = state and (state.kind == "similar" and _("No similar books found.")
            or state.kind == "search" and _("No search results.") or _("No books found."))
            or _("Choose For you or search to discover books."),
        on_refresh = function()
            self:loadDiscoveryBatch(state and state.kind or "recommend", state and state.keyword,
                state and state.cursor or 0, false, true, state)
        end,
    })
end

function M:cancelDiscoveryRequest()
    require("weread.ui.category_catalog").cancel(self)
    return require("weread.ui.discovery_request").cancel(self)
end

function M:loadDiscoveryBatch(kind, keyword, cursor, previous, refresh, context)
    return require("weread.ui.discovery_request").load(self, kind, keyword, cursor, previous, refresh, context)
end

return M
