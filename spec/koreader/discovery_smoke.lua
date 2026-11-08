-- Real KOReader runtime, widgets, font rasterizer, SQLite and plugin init.
-- Use a fresh isolated KO_HOME. No real account or WeRead network requests.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
local evidence = assert(os.getenv("WEREAD_EVIDENCE"))
local source = assert(os.getenv("WEREAD_SOURCE"))
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("color_rendering", false)
require("gettext").changeLang("zh_CN")
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local Screen = Device.screen
assert(require("weread.lib.mock_environment").save{ enabled = true, host = "127.0.0.1", port = assert(tonumber(os.getenv("WEREAD_MOCK_PORT"))) })
local Plugin = dofile(source .. "/main.lua")
local registered = false
local plugin = Plugin:new{ ui = { menu = {
    registerToMainMenu = function() registered = true end,
} } }
assert(registered, "plugin init did not register its menu")
-- Exercise the real HTTP transport against the local synthetic server.
local Data = require("weread.lib.discovery_data")
local first = Data.page("recommend", plugin.client:gateway("/book/recommend", { count = 20, maxIdx = 0 }), 0)
assert(#first.books == 20 and first.has_more)
local second = Data.page("recommend", plugin.client:gateway("/book/recommend", {
    count = 20, maxIdx = first.next_cursor,
}), first.next_cursor)
assert(#second.books == 6 and not second.has_more)
local search = Data.page("search", plugin.client:gateway("/store/search", { keyword = "合成读物", count = 20 }), 0)
assert(#search.books == 20)
local response = plugin.client:get_shelf()
local cover = plugin.client:get_binary("https://weread.qq.com/mock/cover.png", { skip_cookie = true })
assert(plugin:getShelfCoverCache():store(response.books[1], cover))
local function paint(name)
    UIManager:forceRePaint()
    Screen:shot(evidence .. "/" .. name .. ".png")
    assert(plugin.shelf_view and plugin.shelf_view[1][1]:getSize().h == Screen:getHeight())
end
local function flush_tasks()
    -- Native LibraryView buttons defer their callbacks, which then schedule HTTP.
    for _i = 1, 3 do
        UIManager:shiftScheduledTasksBy(-1e9)
        UIManager:setInputTimeout(0)
        UIManager:handleInput()
    end
end
local function press(view, label)
    for _, button in ipairs(view._action_buttons) do
        if button.text == require("weread.lib.plugin_util").tr(label) then
            button.callback()
            return
        end
    end
    error("missing button: " .. label)
end
-- Keep the real scheduled controller/HTTP path and invoke native button callbacks.
plugin.isNetworkOnline = function() return true end
plugin.isNetworkConnected = function() return false end
plugin:showBookMenu(response.books[1])
UIManager:forceRePaint()
Screen:shot(evidence .. "/detail-similar-action.png")
local detail = plugin._book_detail_view
press(detail, "Similar books")
flush_tasks()
assert(plugin.discovery_state.kind == "similar" and #plugin.discovery_state.books == 20
    and plugin.discovery_state.book_id == response.books[1].bookId and plugin._book_detail_view == nil)
local session = plugin.discovery_state.session_id
paint("store-similar")
press(plugin.shelf_view, "Next batch")
flush_tasks()
assert(#plugin.discovery_state.books == 5 and not plugin.discovery_state.has_more
    and plugin.discovery_state.cursor == 20 and plugin.discovery_state.session_id == session)
paint("store-similar-last")
press(plugin.shelf_view, "Previous batch")
flush_tasks()
assert(#plugin.discovery_state.books == 20 and plugin.discovery_state.cursor == 0
    and #plugin.discovery_state.history == 0 and plugin.discovery_state.session_id == session)
-- A pending request must not reopen a manually closed detail page.
plugin:showBookMenu(response.books[2])
press(plugin._book_detail_view, "Similar books")
plugin._book_detail_view:onClose()
flush_tasks()
assert(plugin.discovery_state.book_id == response.books[1].bookId and not plugin.discovery_loading)
-- Public category browsing must also work without a configured login.
plugin.requireLogin = function() error("public bookstore requested login") end
press(plugin.shelf_view, "Browse books")
flush_tasks()
local picker = assert(plugin._discovery_menu)
UIManager:forceRePaint()
Screen:shot(evidence .. "/store-categories.png")
picker:onMenuSelect(picker.item_table[1]) -- rankings
picker:onMenuSelect(picker.item_table[1]) -- rising
flush_tasks()
assert(plugin.discovery_state.kind == "category" and plugin.discovery_state.rank
    and plugin.discovery_state.category_id == "rising" and #plugin.discovery_state.books == 20)
paint("store-rankings")
press(plugin.shelf_view, "Next batch")
flush_tasks()
assert(plugin.discovery_state.cursor == 20 and #plugin.discovery_state.books == 6
    and not plugin.discovery_state.has_more and plugin.discovery_state.history[1] == 0)
press(plugin.shelf_view, "Previous batch")
flush_tasks()
assert(plugin.discovery_state.cursor == 0 and #plugin.discovery_state.history == 0)
press(plugin.shelf_view, "Browse books")
flush_tasks()
picker = assert(plugin._discovery_menu)
picker:onMenuSelect(picker.item_table[2]) -- categories
picker:onMenuSelect(picker.item_table[1]) -- literature
UIManager:forceRePaint()
Screen:shot(evidence .. "/store-subcategories.png")
picker:onMenuSelect(picker.item_table[2]) -- fiction, after All in literature
flush_tasks()
assert(plugin.discovery_state.category_id == "100001" and not plugin.discovery_state.rank
    and #plugin.discovery_state.books == 15 and #plugin.discovery_state.history == 0)
paint("store-subcategory-books")
plugin:closeWeReadUI()
plugin.discovery_state = nil
-- Screens now render offline; any unexpected request fails the test.
plugin.isNetworkOnline = function() return false end
plugin.isNetworkConnected = function() return false end
plugin.client.gateway = function() error("unexpected network request") end
plugin.client.get_binary = function() error("unexpected image request") end
plugin.client.get_text = function() error("unexpected public request") end
plugin:showHome()
paint("home-empty")
local books = response.books
plugin.library_db:cacheShelf(books, response.archive)
plugin:showHome()
paint("home-recent")
plugin.shelf_view.on_page_changed(2)
paint("home-page-two")
plugin:closeWeReadUI()
plugin:showBookshelf()
paint("shelf-covers")
plugin.shelf_view.on_display_change("view_mode", "list")
paint("shelf-list")
plugin:closeWeReadUI()
plugin:showBookstore()
paint("store-empty")
plugin.discovery_state = {
    account = plugin.library_db:accountKey(), books = books, loaded_at = os.time(),
    kind = "recommend", cursor = 0, next_cursor = 26, has_more = true, history = { 0 },
}
plugin:showBookstore()
paint("store-recommend")
plugin.discovery_state.kind, plugin.discovery_state.keyword = "search", "中文长标题搜索测试"
plugin:showBookstore()
paint("store-search")
plugin.shelf_view:onClose()
assert(plugin.shelf_view == nil, "closing store retained a stale view")
plugin:onWeReadAccountChanged()
assert(plugin.discovery_state == nil, "account change retained discovery data")
print("PASS: real HTTP recommendations/search/similar/categories/rankings/shelf/covers, native buttons and menus, scheduled requests, SQLite, rendering, pagination, close and account cleanup")
UIManager:quit()
