-- Regression coverage for full-screen WeRead views left in UIManager's stack.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local closed = {}
package.preload["ui/uimanager"] = function()
    return {
        close = function(_self, view) closed[#closed + 1] = view end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end

for _, name in ipairs({
    "ui/widget/buttondialog",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
    "ui/widget/inputdialog",
    "ui/widget/progressbardialog",
    "ui/widget/textviewer",
}) do
    package.preload[name] = function() return {} end
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = function() return {} end
package.preload["weread.lib.content"] = function()
    return { load_catalog_cache = function() return nil end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end

local detail_view = { id = "detail" }
local chapter_view = { id = "chapters" }
local detail_data, detail_callbacks
package.preload["weread.ui.book_detail_view"] = function()
    return { show = function(data, callbacks)
        detail_data, detail_callbacks = data, callbacks
        return detail_view
    end }
end
package.preload["weread.ui.chapter_list_view"] = function()
    return { show = function() return chapter_view end }
end

local Library = require("weread.ui.library")
local books = {}
local opened, similar_book
local host = {
    settings = {
        get = function(_self, key, default)
            if key == "books" then return books end
            return default
        end,
    },
    ui = {
        openFile = function(_self, path) opened = path end,
    },
    getFullBookCachePath = function() return "/missing.epub" end,
    bookRecordHasDownload = function() return false end,
    safeCallback = function(_self, _label, callback) return callback end,
    showInfo = function() end,
    showSimilarBooks = function(_self, book) similar_book = book end,
    loadChapters = function(_self, _book, callback)
        callback({ { chapterUid = 1, title = "One", wordCount = 10 } })
    end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

local book = { book_id = "book", title = "Book", chapters = {} }
host:showBookMenu(book)
expect(host._book_detail_view == detail_view,
    "book detail view was not tracked")
expect(detail_data.actions[1].text == "Similar books", "detail omitted similar books action")
detail_data.actions[1].callback()
expect(similar_book == book, "similar books action used a different seed")
local old_epoch = host.discovery_epoch or 0
detail_callbacks.on_close()
expect(host._book_detail_view == nil and host.discovery_epoch == old_epoch + 1,
    "detail close did not invalidate pending discovery requests")
host:showBookMenu(book)

host:showChapterList(book)
expect(host._chapter_list_view == chapter_view,
    "chapter list view was not tracked")

local shelf_view = { id = "shelf" }
host.shelf_view = shelf_view
host:openFile("/cache/book.epub")
expect(opened == "/cache/book.epub", "document was not opened")
expect(#closed == 3
        and closed[1] == chapter_view
        and closed[2] == detail_view
        and closed[3] == shelf_view,
    "WeRead views were not closed from topmost to bottommost")
expect(host._chapter_list_view == nil
        and host._book_detail_view == nil
        and host.shelf_view == nil,
    "closed WeRead view references were retained")

closed = {}
host.shelf_view = shelf_view
host:openFile(nil)
expect(#closed == 0 and host.shelf_view == shelf_view,
    "invalid open request unexpectedly closed the bookshelf")

print(("library_ui_cleanup_spec: %d checks"):format(checks))
