package.path = "./?.lua;./?/init.lua;" .. package.path
local Data = require("weread.lib.discovery_data")
local Header = require("weread.lib.home_header_layout")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local result = Data.page("search", { hasMore = 1, results = {
    { books = { { searchIdx = 4, bookInfo = { bookId = "a", title = "A" } },
        { searchIdx = 8, bookInfo = { bookId = "a" } }, false, { bookId = "b", idx = 9 } } },
} }, 0)
expect(#result.books == 2 and result.next_cursor == 9 and result.has_more, "search deduplication or cursor lost")
expect(not Data.page("recommend", { books = { { bookId = "a" } }, hasMore = true }, 9).has_more,
    "non-advancing cursor must not cause an endless next-batch loop")
expect(not pcall(Data.page, "recommend", {}, 0), "malformed response treated as empty success")
expect(#Data.page("search", { results = {} }, 0).books == 0, "empty search rejected")
local books = { { bookId = "a", readUpdateTime = 10 }, { bookId = "b", readUpdateTime = 20 }, { bookId = "c" } }
expect(Data.recent(books)[1].bookId == "b" and books[1].bookId == "a", "recent sort mutated shelf order")
expect(#Data.recent(books) == 2, "unread books included in recent reading")
local saved_reading = { c = { recent_read_at = 30, recent_read_account = "a" } }
expect(Data.recent(books, saved_reading, "a")[1].bookId == "c", "offline reading missing from home")
expect(#Data.recent(books, saved_reading, "b") == 2, "local reading leaked across accounts")
expect(books[1]._recent_time == nil, "recent metadata mutated cloud shelf")
for _, width in ipairs({ 120, 320, 600, 1072, 1440 }) do
    local layout = Header.arrange(width, {
        { key = "back", width = 72 }, { key = "title", width = 200 },
        { key = "search", width = 72 }, { key = "refresh", width = 72 },
    }, 0)
    for i, item in ipairs(layout) do
        expect(item.x >= 0 and item.x + item.width <= width, "header exceeds viewport")
        expect(i == 1 or item.x >= layout[i - 1].x + layout[i - 1].width, "header overlaps")
    end
end

package.preload["ui/uimanager"] = function() return { close = function() end } end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s) return s end, display_error = tostring }
end
local Discovery = require("weread.ui.discovery")
local queued, requests, rendered, error_text, account = nil, {}, 0, nil, "account-a"
local fail = false
local plugin = setmetatable({
    library_db = { accountKey = function() return account end },
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _title, fn) queued = fn return true end,
    client = { gateway = function(_self, api, params)
        requests[#requests + 1] = { api = api, params = params }
        if fail then error("offline") end
        return { books = { { bookId = "a", searchIdx = params.maxIdx + 20 } }, hasMore = true }
    end },
    showInfo = function(_self, message) error_text = message end,
    showBookstore = function() rendered = rendered + 1 end,
}, { __index = Discovery })
plugin:loadDiscoveryBatch("recommend", nil, 0)
expect(#requests == 0 and plugin.discovery_loading, "request bypassed online task")
queued()
expect(rendered == 1 and requests[1].api == "/book/recommend", "recommendations not displayed")
expect(plugin.discovery_state.next_cursor == 20, "next cursor lost")
plugin:loadDiscoveryBatch("recommend", nil, 20)
queued()
expect(plugin.discovery_state.history[1] == 0, "previous batch cursor not retained")
plugin:loadDiscoveryBatch("recommend", nil, 0, true)
queued()
expect(#plugin.discovery_state.history == 0, "back navigation did not consume cursor")
local saved = plugin.discovery_state
fail = true
plugin:loadDiscoveryBatch("recommend", nil, 20)
queued()
expect(plugin.discovery_state == saved and error_text, "failure discarded visible books")
fail = false
plugin:loadDiscoveryBatch("recommend", nil, 20)
plugin.discovery_epoch = 1
queued()
expect(plugin.discovery_state == saved and rendered == 3, "late result reopened a closed page")
plugin:loadDiscoveryBatch("recommend", nil, 20)
account = "account-b"
queued()
expect(plugin.discovery_state == saved, "result crossed account boundary")
plugin.runOnlineTask = function() return false end
plugin:loadDiscoveryBatch("recommend", nil, 20)
expect(not plugin.discovery_loading, "cancelled network task left loading locked")

-- Cover completion rebuilds widgets; it must not invalidate the current request.
plugin.runOnlineTask = function(_self, _title, fn) queued = fn return true end
plugin:loadDiscoveryBatch("recommend", nil, 0)
plugin.shelf_view = {}
queued()
expect(plugin.discovery_state.account == "account-b" and rendered == 4, "cover redraw discarded current result")

local shown, opened, fetched
package.preload["weread.ui.library_view"] = function()
    return {
        getLayout = function(_cover, _count, _mode, reserved)
            expect(reserved == 108, "home did not reserve actions and navigation")
            return { page_size = 6, columns = 3, rows = 2 }
        end,
        show = function(data, callbacks)
            shown = { data = data, callbacks = callbacks }
            return { page = data.page, page_size = data.page_size }
        end,
    }
end
plugin.settings = { get = function() return { a = { book_id = "a", cached_chapters = {} } } end }
plugin.getShelfCoverCache = function() return { pathFor = function() return nil end } end
plugin.isBookDownloaded = function() return true end
plugin.fetchVisibleShelfCovers = function(_self, _view, _books, options) fetched = options end
plugin.openBookForReading = function(_self, book) opened = book end
plugin.closeWeReadUI = function(self) self.shelf_view = nil self.discovery_epoch = self.discovery_epoch + 1 end
plugin:showDiscoveryPage("home", { { bookId = "a" } }, { title = "Home" })
expect(shown.data.portal and #shown.data.navigation == 3, "home navigation missing")
shown.callbacks.on_select({ bookId = "a", _cached = true })
expect(opened and opened.cached_chapters, "offline continue did not use saved chapter cache")
fetched.on_redraw(1)
expect(shown.data.title == "Home", "cover completion lost home context")
shown.callbacks.on_close()
expect(plugin.shelf_view == nil, "close left stale discovery view")
local persisted, flushed
plugin.settings = {
    get = function() return { a = { book_id = "a" } } end,
    set = function(_self, _key, value) persisted = value end,
    flush = function() flushed = true end,
}
plugin:recordRecentReading("a")
expect(flushed and persisted.a.recent_read_at > 0 and persisted.a.recent_read_account == "account-b",
    "local reading was not persisted with account identity")
print("discovery_spec: " .. checks .. " checks")
