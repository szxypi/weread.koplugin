package.path = "./?.lua;" .. package.path
local shown, pending, requests, errors = {}, nil, {}, 0
local function empty() return {} end
for _, name in ipairs({ "weread.lib.book_store", "ui/widget/confirmbox", "weread.lib.content",
    "weread.lib.shelf_groups", "weread.lib.shelf_flags", "weread.lib.shelf_search",
    "weread.lib.shelf_time", "weread.lib.volatile_shelf", "ui/widget/inputdialog",
    "ui/widget/textviewer", "weread.lib.protocol", "weread.lib.read_access" }) do
    package.preload[name] = empty
end
package.preload["weread.lib.logger"] = function() return { err = function() end } end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(x) return x end, T = function(x) return x end,
        log_error = tostring, display_error = tostring }
end
package.preload["ui/uimanager"] = function()
    return { close = function(_, view) view._review_closed = true end }
end
package.preload["weread.ui.book_reviews_view"] = function()
    return { show = function(data, callbacks)
        local view = { data = data, callbacks = callbacks }
        shown[#shown + 1] = view
        return view
    end }
end
local Library = require("weread.ui.library")
local pages = {
    { reviewsHasMore = 1, synckey = 12, reviews = {
        { idx = 4, review = { reviewId = "a", content = "one", star = 100 } },
    } },
    { reviewsHasMore = 1, synckey = 13, reviews = {
        { idx = 7, review = { reviewId = "b", content = "two", star = 60 } },
    } },
}
local host = {
    requireLogin = function() return true end,
    showBusy = function() end,
    closeBusy = function() end,
    showInfo = function() errors = errors + 1 end,
    runOnlineTask = function(_, _, callback) pending = callback return true end,
    client = { get_book_reviews = function(_, book, mode, count, cursor, sync)
        requests[#requests + 1] = { book, mode, count, cursor, sync }
        local page = table.remove(pages, 1)
        if page == false then error("temporary failure") end
        return page
    end },
}
for k, v in pairs(Library) do if host[k] == nil then host[k] = v end end
host:showBookReviews({ book_id = "42", title = "Book" })
assert(#shown == 0 and pending)
pending(); pending = nil
assert(#shown == 1 and requests[1][2] == 1 and requests[1][4] == nil)
assert(shown[1].data.result.items[1].rating == 5)
shown[1].callbacks.on_load_more()
assert(pending)
pending(); pending = nil
assert(#shown == 2 and shown[1]._review_closed)
assert(requests[2][4] == 4 and requests[2][5] == 12)
assert(#shown[2].data.result.items == 2 and shown[2].data.result.has_more)
-- Switching tabs uses an independent first-page request, then cached results.
pages[1] = { reviewsHasMore = 0, reviews = {} }
shown[2].callbacks.on_switch("latest")
pending(); pending = nil
assert(requests[3][2] == 3 and requests[3][4] == nil)
shown[3].callbacks.on_switch("recommended")
assert(#requests == 3 and #shown[4].data.result.items == 2)
-- A failed request retains the current page and does not cache the failure.
pages[1] = false
shown[4].callbacks.on_load_more()
pending(); pending = nil
assert(errors == 1 and not shown[4]._review_closed)
-- Closing the view while a request is pending must not reopen it.
pages[1] = { reviewsHasMore = 0, reviews = {} }
shown[4].callbacks.on_load_more()
shown[4]._review_closed = true
pending()
assert(#shown == 4 and errors == 1)
print("book_reviews_pagination_spec: paging, tab cache, failure and close passed")
