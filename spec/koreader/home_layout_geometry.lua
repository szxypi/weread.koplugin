-- Real KOReader widgets; font/framebuffer doubles from the existing geometry fixture.
dofile("spec/empty_state_face_spec.lua")
assert(os.getenv("KOREADER_WIDGET_DIR"), "KOReader source required")
local Screen = require("device").screen
local View = require("weread.ui.library_view")
local Home = require("weread.lib.home_layout")
local navigation = { { text = "Home" }, { text = "Bookshelf" }, { text = "Store" }, { text = "My" } }
for _, dimensions in ipairs({ { 320, 480 }, { 600, 800 }, { 800, 600 }, { 1264, 1680 }, { 1440, 1920 } }) do
    local width, height = dimensions[1], dimensions[2]
    Screen.getWidth, Screen.getHeight = function() return width end, function() return height end
    Screen.scaleBySize = function(_self, value) return math.floor(value * math.min(width, height) / 600) end
    local baseline = View.getLayout(true, 24, "books", 108, { home = Home.normalize(nil) })
    for _, config in ipairs({ {}, { density = "compact" }, { view_mode = "list" },
        { show_status = false, show_summary = false, shortcuts = {} },
        { sections = { "recent", "shortcuts", "status", "summary" } } }) do
        local preferences = Home.normalize(config)
        for _, count in ipairs({ 0, 1, 24 }) do
            local books, actions = {}, {}
            for index = 1, count do books[index] = { bookId = tostring(index), title = "A long title for layout" } end
            for _, key in ipairs(preferences.shortcuts) do actions[#actions + 1] = { text = key } end
            local cover_mode = preferences.view_mode == "cover"
            local layout = View.getLayout(cover_mode, count, "books", 108, { home = preferences })
            local view = View.show({
                mode = "books", portal = true, home_layout = preferences, title = "WeRead home",
                status_text = "01-01 10:00 Battery 100% Wi-Fi connected", summary_text = "Today 15 / 30 minutes",
                books = books, actions = actions, navigation = navigation, paged = true,
                cover_mode = cover_mode, page = 1, page_size = layout.page_size,
                cover_columns = layout.columns, cover_rows = layout.rows,
            }, { on_settings = function() end, on_refresh = function() end })
            assert(view[1][1]:getSize().h == height, "custom home exceeds viewport height")
            assert(view[1][1]:getSize().w <= width, "custom home exceeds viewport width")
            assert(view.scroll[1]:getSize().h <= view.scroll.dimen.h, "home content exceeds reserved space")
            assert(view.settings_button and #view._navigation_buttons == 4, "settings/navigation unreachable")
            if preferences.density == "compact" and count == 24 then
                assert(layout.page_size >= baseline.page_size, "compact layout shows fewer covers")
            end
            view:onClose()
        end
    end
    print(string.format("PASS home layouts: %dx%d, five configurations, empty/single/24 books", width, height))
end
