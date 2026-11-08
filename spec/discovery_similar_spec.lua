package.path = "./?.lua;./?/init.lua;" .. package.path
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local closed = {}
package.preload["ui/uimanager"] = function()
    return { close = function(_self, view) closed[#closed + 1] = view end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s, v) return (s:gsub("%%1", v)) end,
        display_error = tostring }
end
local Discovery = require("weread.ui.discovery")
local pending, requests, rendered, message, page, failure
local account, logged_in = "a", true
requests, rendered = {}, 0
local plugin = setmetatable({
    library_db = { accountKey = function() return account end },
    requireLogin = function() return logged_in end,
    runOnlineTask = function(_self, _title, fn) pending = fn return true end,
    client = { gateway = function(_self, api, params)
        requests[#requests + 1] = { api = api, params = params }
        if failure then error("offline") end
        return page
    end },
    showInfo = function(_self, text) message = text end,
    showBookstore = function() rendered = rendered + 1 end,
}, { __index = Discovery })
local function response(session, cursor, more)
    return { booksimilar = { sessionId = session, hasMore = more, books = {
        { idx = cursor, book = { bookInfo = { bookId = "result-" .. cursor, title = "Book" } } },
    } } }
end
local seed = { bookId = "seed-a", title = "Seed A" }
logged_in = false
plugin:showSimilarBooks(seed)
expect(not pending and #requests == 0, "logged-out similar request started")
logged_in = true
plugin:showSimilarBooks({})
expect(not pending, "missing seed accepted")
local detail = {}
plugin._book_detail_view = detail
page = response("session-a", 20, true)
plugin:showSimilarBooks(seed)
expect(#requests == 0 and plugin.discovery_loading and plugin._book_detail_view == detail,
    "request did not retain details while waiting")
pending()
local state = plugin.discovery_state
expect(requests[1].api == "/book/similar" and requests[1].params.bookId == "seed-a"
    and requests[1].params.sessionId == nil, "initial similar request parameters incorrect")
expect(state.kind == "similar" and state.book_id == "seed-a" and state.book_title == "Seed A"
    and state.session_id == "session-a" and #state.history == 0, "seed/session not saved")
expect(plugin._book_detail_view == nil and closed[1] == detail and rendered == 1,
    "successful similar request did not replace details")
page = response("session-a", 40, false)
plugin:loadDiscoveryBatch("similar", nil, state.next_cursor, false, false, state)
pending()
state = plugin.discovery_state
expect(requests[2].params.sessionId == "session-a" and requests[2].params.maxIdx == 20
    and requests[2].params.bookId == "seed-a", "next batch lost original session/seed")
expect(state.history[1] == 0 and not state.has_more, "next history or final batch incorrect")
page = response("session-a", 20, true)
plugin:loadDiscoveryBatch("similar", nil, state.history[1], true, false, state)
pending()
state = plugin.discovery_state
expect(#state.history == 0 and requests[3].params.sessionId == "session-a", "previous batch lost session")
plugin:loadDiscoveryBatch("similar", nil, state.cursor, false, true, state)
pending()
expect(#plugin.discovery_state.history == 0, "refresh appended cursor history")
state = plugin.discovery_state
failure = true
detail = {}
plugin._book_detail_view = detail
plugin:showSimilarBooks({ bookId = "seed-b", title = "Seed B" })
pending()
expect(plugin.discovery_state == state and plugin._book_detail_view == detail and message,
    "failed new seed discarded current list or details")
failure = false
page = response("wrong-session", 40, true)
plugin:loadDiscoveryBatch("similar", nil, 20, false, false, state)
pending()
expect(plugin.discovery_state == state and message:find("Similar recommendations changed", 1, true),
    "changed session mixed recommendation pages")
page = response(nil, 40, true)
plugin:loadDiscoveryBatch("similar", nil, 20, false, false, state)
pending()
expect(plugin.discovery_state == state, "missing continuation session accepted")
page = response("session-b", 20, true)
plugin:showSimilarBooks({ book_id = "seed-b", title = "Seed B" })
pending()
state = plugin.discovery_state
expect(state.book_id == "seed-b" and #state.history == 0 and state.session_id == "session-b",
    "different seed inherited previous cursor history")
page = response(nil, 20, true)
plugin:showSimilarBooks(seed)
pending()
expect(not plugin.discovery_state.has_more, "sessionless first page offered unsafe continuation")
local count = #requests
plugin:loadDiscoveryBatch("similar", nil, 20, false, false, plugin.discovery_state)
expect(#requests == count and not plugin.discovery_loading, "sessionless continuation requested")
state = plugin.discovery_state
page = response("session-a", 20, true)
plugin:showSimilarBooks(seed)
plugin.discovery_epoch = 1
pending()
expect(plugin.discovery_state == state and not plugin.discovery_loading, "closing detail reopened similar page")
plugin:showSimilarBooks(seed)
account = "b"
pending()
expect(plugin.discovery_state == state, "similar result crossed accounts")
account = "a"
plugin.runOnlineTask = function() return false end
plugin:showSimilarBooks(seed)
expect(not plugin.discovery_loading, "cancelled similar request locked loading")

-- Verify rendered title and the callbacks carry the seed/session in both directions.
plugin.discovery_state = {
    kind = "similar", account = "a", book_id = "seed-a", book_title = "Seed A",
    session_id = "session-a", books = {}, cursor = 20, next_cursor = 40,
    history = { 0 }, has_more = true, loaded_at = os.time(),
}
local shown, query
plugin.showDiscoveryPage = function(_self, _tab, _books, options) shown = options end
plugin.loadDiscoveryBatch = function(_self, ...) query = { ... } end
Discovery.showBookstore(plugin)
expect(shown.title == "Similar to: Seed A" and shown.empty_text == "No similar books found.",
    "similar title/empty state not rendered")
shown.actions[3].callback()
expect(query[3] == 40 and query[6].session_id == "session-a", "next UI callback lost session")
shown.actions[4].callback()
expect(query[3] == 0 and query[4] and query[6].book_id == "seed-a", "previous UI callback lost seed")
shown.on_refresh()
expect(query[3] == 20 and query[5] and query[6].session_id == "session-a", "refresh UI callback lost session")
shown.actions[1].callback()
expect(query[1] == "recommend" and query[6] == nil, "For you retained similar context")
print("discovery_similar_spec: " .. checks .. " checks")
