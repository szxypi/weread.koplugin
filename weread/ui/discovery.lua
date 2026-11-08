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
    }
end

function M:showDiscoveryPage(tab, books, options)
    local LibraryView = require("weread.ui.library_view")
    options = options or {}
    local layout = LibraryView.getLayout(true, #books, "books", 108)
    local page = math.max(1, math.min(options.page or 1, math.max(1, math.ceil(#books / layout.page_size))))
    local cover_paths = {}
    local cache = self:getShelfCoverCache()
    local saved, downloaded = self.settings:get("books", {}), {}
    for index = (page - 1) * layout.page_size + 1, math.min(#books, page * layout.page_size) do
        local book = books[index]
        cover_paths[book] = cache:pathFor(book)
        book._cached = self:isBookDownloaded(book, saved, downloaded)
    end
    self.shelf_cover_generation = (self.shelf_cover_generation or 0) + 1
    if self.shelf_view then UIManager:close(self.shelf_view) end
    local function redraw(next_page)
        options.page = next_page
        self:showDiscoveryPage(tab, books, options)
    end
    local view
    view = LibraryView.show({
        mode = "books", portal = true, title = options.title,
        empty_text = options.empty_text, actions = options.actions,
        navigation = self:discoveryNavigation(tab), books = books,
        cover_mode = true, paged = true, page = page,
        page_size = layout.page_size, cover_columns = layout.columns,
        cover_rows = layout.rows, cover_paths = cover_paths,
    }, {
        on_search = function() self:showDiscoverySearch() end,
        on_refresh = options.on_refresh,
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
    self:fetchVisibleShelfCovers(view, books, { on_redraw = redraw })
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

function M:showHome()
    local cached = self.library_db and self.library_db:getShelf() or {}
    local archives = self.library_db and self.library_db:getShelfArchives() or {}
    self:applyShelfSnapshot(cached or {}, archives)
    self:showDiscoveryPage("home", Data.recent(self.shelf_regular, self.settings:get("books", {}),
        self.library_db and self.library_db:accountKey()), {
        title = _("WeRead home"),
        empty_text = _("No recent reading. Refresh or open your bookshelf."),
        actions = {
            { text = _("Recently read"), enabled = false },
            { text = _("All books"), callback = function()
                self:closeWeReadUI()
                self:showBookshelf()
            end },
        },
        on_refresh = function()
            self:refreshBookshelf(self.shelf_view, { on_loaded = function() self:showHome() end })
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

function M:showBookstore()
    local state = self.discovery_state
    if state and state.account ~= self.library_db:accountKey() then
        self.discovery_state = nil
        state = nil
    end
    local actions = {
        { text = _("For you"), callback = function() self:loadDiscoveryBatch("recommend", nil, 0) end },
        { text = _("Search WeRead"), callback = function() self:showDiscoverySearch() end },
    }
    if state and state.has_more then
        actions[#actions + 1] = { text = _("Next batch"), callback = function()
            self:loadDiscoveryBatch(state.kind, state.keyword, state.next_cursor)
        end }
    end
    if state and #state.history > 0 then
        actions[#actions + 1] = { text = _("Previous batch"), callback = function()
            self:loadDiscoveryBatch(state.kind, state.keyword, state.history[#state.history], true)
        end }
    end
    local title = _("Bookstore")
    if state then
        title = state.kind == "search" and PluginUtil.T(_("Search: %1"), state.keyword) or _("For you")
        if os.time() - state.loaded_at > Data.CACHE_TTL then title = title .. " · " .. _("Cached") end
    end
    self:showDiscoveryPage("store", state and state.books or {}, {
        title = title, actions = actions,
        empty_text = state and _("No search results.") or _("Choose For you or search to discover books."),
        on_refresh = function()
            self:loadDiscoveryBatch(state and state.kind or "recommend", state and state.keyword,
                state and state.cursor or 0, false, true)
        end,
    })
end

function M:loadDiscoveryBatch(kind, keyword, cursor, previous, refresh)
    if self.discovery_loading or not self:requireLogin(false, true) then return end
    local account = self.library_db:accountKey()
    local epoch, source_state = self.discovery_epoch or 0, self.discovery_state
    self.discovery_loading = true
    local started = self:runOnlineTask(_("Bookstore"), function()
        if account ~= self.library_db:accountKey() or (self.discovery_epoch or 0) ~= epoch then
            self.discovery_loading = nil
            return
        end
        local ok, result = pcall(function()
            local data = self.client:gateway(kind == "search" and "/store/search" or "/book/recommend", {
                keyword = keyword, count = Data.PAGE_SIZE, maxIdx = cursor,
                scope = kind == "search" and 10 or nil,
            })
            return Data.page(kind, data, cursor)
        end)
        self.discovery_loading = nil
        if account ~= self.library_db:accountKey() or (self.discovery_epoch or 0) ~= epoch then return end
        if not ok then
            self:showInfo(PluginUtil.T(_("Bookstore request failed:\n%1"), PluginUtil.display_error(result)))
            return
        end
        local history = {}
        if source_state and source_state.kind == kind and source_state.keyword == keyword then
            for i, value in ipairs(source_state.history) do history[i] = value end
            if previous then table.remove(history)
            elseif not refresh and cursor ~= 0 then history[#history + 1] = source_state.cursor
            elseif not refresh then history = {} end
        end
        -- Cursor history is bounded and contains no book/user payloads.
        if #history > 100 then table.remove(history, 1) end
        result.kind, result.keyword, result.cursor = kind, keyword, cursor
        result.history, result.account, result.loaded_at = history, account, os.time()
        self.discovery_state = result
        self:showBookstore()
    end)
    if started == false then self.discovery_loading = nil end
end

return M
