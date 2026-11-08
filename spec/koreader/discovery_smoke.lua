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
local require_login = plugin.requireLogin
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
    local socket=require("socket")
    local deadline=socket.gettime()+15
    while plugin.discovery_loading or plugin.statistics_request do
        assert(socket.gettime()<deadline,"bookstore worker deadline")
        UIManager:shiftScheduledTasksBy(-1e9)
        UIManager:setInputTimeout(0)
        UIManager:handleInput()
        socket.sleep(0.01)
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
-- Real subprocess, actual account-scoped SQLite and local-over-cloud display.
plugin.requireLogin = require_login
local fetch_covers = plugin.fetchVisibleShelfCovers
plugin.fetchVisibleShelfCovers = function() end
plugin.library_db:cacheShelf(response.books, response.archive)
local shelf_settings = plugin.settings:get("shelf")
shelf_settings.sort_order = "default"
plugin.settings:set("shelf", shelf_settings)
local seed_id = response.books[1].bookId
local saved = plugin.settings:get("books", {})
saved[seed_id] = { book_id = seed_id, title = response.books[1].title,
    recent_read_account = plugin.library_db:accountKey(), recent_read_at = os.time(), progress = 83, chapter_uid = 99,
    pending_upload_position = { book_id = seed_id, percent = 83, chapter_uid = 99 },
}
plugin.settings:set("books", saved)
plugin.settings:flush()
local function wait_progress()
    for _i = 1, 200 do
        flush_tasks()
        if plugin.shelf_progress_worker and not plugin.shelf_progress_worker:busy() then return end
        require("ffi/util").usleep(50000)
    end
    error("shelf progress worker timed out")
end
plugin:showBookshelf()
wait_progress()
local snapshot = plugin.library_db:getShelfProgress({ seed_id })[seed_id]
assert(snapshot and snapshot.percent == 37, "real HTTP progress did not persist")
assert(plugin.shelf_view.books[1]._shelf_progress == 83 and plugin.shelf_view.books[1]._shelf_progress_local,
    "cloud display overwrote pending local progress")
local preserved = plugin.settings:get("books", {})[seed_id]
assert(preserved.progress == 83 and preserved.chapter_uid == 99 and preserved.pending_upload_position.percent == 83,
    "display refresh changed the reader's sync position")
paint("shelf-progress")
plugin.shelf_view.on_page_changed(2)
wait_progress()
local next_id = plugin.shelf_view.books[plugin.shelf_view.page_size + 1].bookId
assert(plugin.library_db:getShelfProgress({ next_id })[next_id].percent == 0, "next shelf page did not fetch progress")
plugin.shelf_view.on_page_changed(1)
plugin.isNetworkOnline = function() return false end
plugin.shelf_view.on_display_change("view_mode", "list")
assert(plugin.shelf_view:itemStatus(plugin.shelf_view.books[1]):find("83%%"), "offline list lost pending progress")
paint("shelf-progress-list")
plugin.isNetworkOnline = function() return true end
plugin.shelf_view.on_display_change("paginated", false)
wait_progress()
paint("shelf-progress-scroll-start")
assert(plugin.shelf_view.scroll:onScrollPageDown(), "native long-list scroll did not move")
wait_progress()
local scrolled = plugin.shelf_view:getScrollOffset().y
local visible_books = plugin.shelf_view:getVisibleBooks()
assert(scrolled > 0 and visible_books[1].bookId ~= seed_id, "long-list view returned invisible first row")
local visible_ids = {}
for _, book in ipairs(visible_books) do visible_ids[#visible_ids + 1] = book.bookId end
local scrolled_snapshots = plugin.library_db:getShelfProgress(visible_ids)
for _, id in ipairs(visible_ids) do assert(scrolled_snapshots[id], "scroll did not fetch visible progress") end
assert(plugin.shelf_view:getScrollOffset().y == scrolled, "progress redraw reset scroll offset")
paint("shelf-progress-scroll")
plugin:closeWeReadUI()
local original_account = plugin.settings:get("account")
plugin.settings:set("account", { user_vid = "90009999" })
assert(next(plugin.library_db:getShelfProgress({ seed_id })) == nil, "snapshot leaked across accounts")
plugin.settings:set("account", original_account)
-- My page uses real gateway stats, background workers, native goal input and SQLite.
local fixtures=debug.getinfo(1,"S").source:match("^@(.*/)")
dofile(fixtures.."shelf_progress_smoke.lua")(plugin,flush_tasks,evidence,paint,wait_progress)
local function paint_profile(name)
    UIManager:forceRePaint()
    Screen:shot(evidence .. "/" .. name .. ".png")
    assert(plugin._profile_view[1]:getSize().h == Screen:getHeight(), "profile height exceeds screen")
    assert(plugin._profile_view[1]:getSize().w <= Screen:getWidth(), "profile width exceeds screen")
end
plugin.isNetworkOnline = function() return false end
plugin:showProfile()
assert(not plugin._profile_view.data.has_data and not plugin.profile_request, "empty offline profile invented data")
paint_profile("profile-empty")
plugin:closeWeReadUI()
plugin.isNetworkOnline = function() return true end
plugin:showProfile()
for _i = 1, 200 do
    flush_tasks()
    if not plugin.profile_request then break end
    require("ffi/util").usleep(50000)
end
assert(plugin._profile_view.data.has_data and not plugin.profile_request, "profile stats worker failed")
assert(#plugin._profile_view._navigation_buttons == 4 and #plugin._profile_view._calendar_cells >= 28,
    "profile navigation/calendar missing")
paint_profile("profile")
plugin._profile_view._profile_buttons[1].callback()
flush_tasks()
local goal_dialog = assert(plugin._profile_goal_dialog)
goal_dialog:setInputText("45")
goal_dialog.buttons[1][2].callback()
assert(plugin.library_db:getProfileState("goal").minutes == 45
    and plugin._profile_view.data.goal_minutes == 45 and plugin._profile_goal_dialog == nil,
    "native goal input did not persist")
paint_profile("profile-goal")
plugin._profile_view._profile_buttons[2].callback()
flush_tasks()
assert(plugin._read_stats_view and plugin._read_stats_view.data.mode == "monthly", "detailed statistics did not open")
plugin._read_stats_view._tab_buttons[1].callback()
flush_tasks()
assert(plugin._read_stats_view.data.mode == "weekly", "statistics tab did not switch")
plugin._read_stats_view:onClose()
assert(plugin._read_stats_view == nil and plugin._profile_view, "statistics close lost the My page")
plugin._profile_view._profile_buttons[1].callback()
flush_tasks()
assert(plugin._profile_goal_dialog, "goal dialog did not reopen")
plugin:onWeReadAccountChanged()
assert(plugin._profile_goal_dialog == nil and plugin._profile_view == nil, "account cleanup retained profile input/window")
plugin.settings:set("account", { user_vid = "90009999" })
assert(plugin.library_db:getProfileState("statistics") == nil and plugin.library_db:getProfileState("goal") == nil,
    "profile cache/goal crossed accounts")
plugin.settings:set("account", original_account)
plugin.settings:flush()
plugin.isNetworkOnline = function() return false end
plugin:showProfile()
assert(plugin._profile_view.data.has_data and plugin._profile_view.data.cached and plugin._profile_view.data.goal_minutes == 45 and not plugin.profile_request,
    "offline profile failed to reopen cached data")
paint_profile("profile-offline")
plugin._profile_view:onClose()
assert(plugin._profile_view == nil, "closing profile retained native window")
plugin.isNetworkOnline = function() return true end
plugin:loadReadStats("monthly")
assert(plugin.busy_message and plugin._stats_busy_generation, "statistics request did not show its loading indicator")
plugin:closeWeReadUI()
flush_tasks()
assert(plugin.busy_message == nil and plugin._read_stats_view == nil, "cancelled statistics retained a spinner or reopened")
plugin.fetchVisibleShelfCovers = fetch_covers
plugin.library_db:cacheShelf({}, {})
shelf_settings = plugin.settings:get("shelf")
shelf_settings.view_mode = "cover"
shelf_settings.paginated = true
plugin.settings:set("shelf", shelf_settings)
-- Screens now render offline; any unexpected request fails the test.
plugin.isNetworkOnline = function() return false end
plugin.isNetworkConnected = function() return false end
plugin.client.gateway = function() error("unexpected network request") end
plugin.client.get_binary = function() error("unexpected image request") end
plugin.client.get_text = function() error("unexpected public request") end
plugin:showHome()
assert(#plugin.shelf_view.books == 0, "empty-home fixture contains cached books")
paint("home-empty")
local books = response.books
plugin.library_db:cacheShelf(books, response.archive)
plugin:showHome()
assert(plugin.shelf_view.books[1]._shelf_progress == 83, "home lost account-bound pending progress")
paint("home-recent")
assert(plugin.shelf_view.settings_button and plugin._home_status_task, "home controls/status timer missing")
plugin:onSuspend()
assert(plugin._home_status_task == nil, "suspend retained the status timer")
plugin:onResume()
assert(plugin._home_status_task, "resume did not restore home status")
local function item(menu, key)
    local label = require("weread.lib.plugin_util").tr(key)
    for _, entry in ipairs(menu.item_table) do
        if type(entry.text) == "string" and entry.text:find(label, 1, true) then return entry end
    end
    error("missing home setting: " .. key)
end
plugin.shelf_view.settings_button.callback()
flush_tasks()
local quick = assert(plugin._home_controls_menu)
UIManager:forceRePaint()
Screen:shot(evidence .. "/home-quick-settings.png")
local behind = plugin.shelf_view
behind.on_page_changed(behind.page)
assert(plugin.shelf_view == behind and plugin._home_pending_redraw, "redraw covered home settings")
quick:onCloseAllMenus()
assert(plugin._home_controls_menu == nil and plugin._home_pending_redraw == nil and plugin.shelf_view ~= behind,
    "settings close did not apply deferred redraw")
plugin.shelf_view.settings_button.callback()
flush_tasks()
quick = plugin._home_controls_menu
quick:onMenuSelect(item(quick, "Home layout"))
local editor = assert(plugin._home_controls_menu)
editor:onMenuSelect(item(editor, "Home book display"))
editor:onMenuSelect(item(editor, "List view"))
assert(plugin.settings:get("home").view_mode == "list" and not plugin.shelf_view.cover_mode, "home list setting did not apply")
plugin._home_controls_menu:onCloseAllMenus()
paint("home-list-layout")
for _i = 1, 3 do
    plugin:showHomeLayoutSettings()
    editor = plugin._home_controls_menu
    editor:onMenuSelect(item(editor, "Home section order"))
    editor:onMenuSelect(item(editor, "Recently read"))
    editor:onMenuSelect(item(editor, "Move up"))
end
assert(plugin.settings:get("home").sections[1] == "recent", "recent module did not move to the top")
plugin._home_controls_menu:onCloseAllMenus()
paint("home-reordered-layout")
assert(plugin.shelf_view._home_status_frame.dimen.y >= plugin.shelf_view.scroll.dimen.y + plugin.shelf_view.scroll.dimen.h,
    "module order did not change rendered placement")
plugin:showHomeLayoutSettings()
editor = plugin._home_controls_menu
editor:onMenuSelect(item(editor, "Clock and device status"))
editor = plugin._home_controls_menu
editor:onMenuSelect(item(editor, "Reading overview"))
editor = plugin._home_controls_menu
editor:onMenuSelect(item(editor, "Home shortcuts"))
assert(not plugin.shelf_view._home_status_label and not plugin._home_status_task, "hidden home widgets retained status polling")
editor = plugin._home_controls_menu
editor:onMenuSelect(item(editor, "Recent reading count"))
editor:onMenuSelect(item(editor, "6"))
assert(#plugin.shelf_view.books == 6, "configured recent reading count ignored")
plugin._home_controls_menu:onCloseAllMenus()
paint("home-minimal-layout")
plugin:showHomeLayoutSettings()
editor = plugin._home_controls_menu
editor:onMenuSelect(item(editor, "Restore default home layout"))
plugin._home_controls_menu:onCloseAllMenus()
assert(plugin.shelf_view.cover_mode and plugin._home_status_task and #plugin.shelf_view.books == 12,
    "restoring home defaults failed")
plugin:showHomeLayoutSettings()
editor = plugin._home_controls_menu
editor:onMenuSelect(item(editor, "Recent reading count"))
editor:onMenuSelect(item(editor, "24"))
plugin._home_controls_menu:onCloseAllMenus()
if Device:hasKeys() then
    local event = require("ui/event")
    assert(plugin.shelf_view.page_count > 1, "24-book home fixture must paginate")
    plugin.shelf_view:handleEvent(event:new("NextPage"))
    assert(plugin.shelf_view.page == 2, "native next-page event did not advance home")
    plugin.shelf_view:handleEvent(event:new("PrevPage"))
    assert(plugin.shelf_view.page == 1, "native previous-page event did not return home")
end
plugin:showHomeLayoutSettings()
editor = plugin._home_controls_menu
editor:onMenuSelect(item(editor, "Restore default home layout"))
plugin._home_controls_menu:onCloseAllMenus()
if Device:hasFrontlight() then
    plugin:showHomeQuickSettings()
    quick = plugin._home_controls_menu
    quick:onMenuSelect(item(quick, "Frontlight"))
    local light_dialog = UIManager._window_stack[#UIManager._window_stack].widget
    assert(light_dialog.name == "FrontLightWidget", "frontlight entry did not use KOReader's control")
    UIManager:forceRePaint()
    Screen:shot(evidence .. "/home-native-frontlight.png")
    light_dialog:onClose()
end
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
print("PASS: HTTP discovery/shelf/progress/statistics; native menus, My calendar/goal/details/offline cache, subprocesses, account SQLite isolation and cleanup")
UIManager:quit()
