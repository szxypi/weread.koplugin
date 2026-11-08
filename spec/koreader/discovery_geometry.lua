-- Native KOReader layout containers; fonts, framebuffer and events are doubles.
-- KOREADER_WIDGET_DIR=/path/to/koreader luajit spec/koreader/discovery_geometry.lua
dofile("spec/empty_state_face_spec.lua")
assert(os.getenv("KOREADER_WIDGET_DIR"), "KOReader checkout required")
local Screen = require("device").screen
local LibraryView = require("weread.ui.library_view")
local callbacks = { on_search = function() end, on_refresh = function() end }
local navigation = {
    { text = "Home", active = true }, { text = "Bookshelf" }, { text = "Bookstore" },
}
local actions = {
    { text = "For you" }, { text = "Search" }, { text = "Next batch" }, { text = "Previous batch" },
}
for _, dimensions in ipairs({ { 320, 480 }, { 600, 800 }, { 800, 600 }, { 1072, 1448 }, { 1440, 1920 } }) do
    local width, height = dimensions[1], dimensions[2]
    Screen.getWidth, Screen.getHeight = function() return width end, function() return height end
    Screen.scaleBySize = function(_self, value) return math.floor(value * math.min(width, height) / 600) end
    for _, count in ipairs({ 0, 1, 30 }) do
        local books = {}
        for index = 1, count do books[index] = { bookId = tostring(index), title = "Book " .. index } end
        local layout = LibraryView.getLayout(true, count, "books", 108)
        local closed = false
        callbacks.on_close = function() closed = true end
        local view = LibraryView.show({
            mode = "books", portal = true, title = "WeRead home", books = books,
            navigation = navigation, actions = actions, paged = true, cover_mode = true,
            page_size = layout.page_size, cover_columns = layout.columns, cover_rows = layout.rows,
        }, callbacks)
        assert(view[1][1]:getSize().h == height, "home/store chrome exceeds viewport")
        assert(view[1][1]:getSize().w <= width, "home/store chrome exceeds screen width")
        assert(view.scroll[1]:getSize().h <= view.scroll.dimen.h, "cover grid exceeds reserved viewport")
        assert(#view._navigation_buttons == 3 and #view._action_buttons == 4)
        assert(view.page_size == layout.page_size, "cover fetch and display page sizes differ")
        view:onClose()
        assert(closed, "back button omitted controller cleanup")
        print(string.format("Discovery geometry: %dx%d, %d books, %dx%d grid", width, height, count,
            layout.columns, layout.rows))
    end
end
