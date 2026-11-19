package.path = './?.lua;' .. package.path
local pending, started, views = {}, {}, {}
local source_valid, source_error, account = true, nil, 'a'
local selected = {api_key = 'synthetic', native = {scope = {vid = '123'}, revision = 1}}
local requests, replies_opened, replies_cancelled, worker_cancelled = {}, 0, 0, 0
local source = {matches = function(_, value) return source_valid and (value == selected or value.key_only == true) end}
source.fetch = function(_, book, mode, previous, access)
    assert(book == '42' and (access == selected or access.key_only))
    requests[#requests + 1] = {mode = mode, previous = previous}
    if source_error then error(source_error, 0) end
    local items = {}
    if previous then for _, item in ipairs(previous.items) do items[#items + 1] = item end end
    local id = mode .. '-' .. (#items + 1)
    items[#items + 1] = {review_id = id, author = 'Reader', content = 'Review', rating = 5, create_time = 0}
    return {items = items, has_more = #items < 3, max_idx = #items, synckey = 12, seen_cursors = {#items}}
end
package.preload['weread.lib.gateway_book_reviews_source'] = function() return source end
package.preload['weread.lib.plugin_util'] = function() return {tr = function(v) return v end} end
package.preload['ui/uimanager'] = function()
    return {close = function(_, view) view._review_closed = true; if view.callbacks then view.callbacks.on_close() end end}
end
package.preload['weread.ui.book_reviews_view'] = function()
    return {show = function(data, callbacks)
        local view = {data = data, result = data.result, callbacks = callbacks}
        views[#views + 1] = view; return view
    end}
end
package.preload['weread.ui.native_review_replies'] = function()
    return {review_id = function(value) return type(value) == 'string' and value ~= '' end,
        open = function(host, parent) replies_opened = replies_opened + 1; host._native_review_replies_owner = {parent = parent} end,
        cancel = function(host) replies_cancelled = replies_cancelled + 1; host._native_review_replies_owner = nil end}
end
package.preload['weread.lib.memory_worker'] = function()
    return {new = function() return {start = function(_, task, callback)
        started[#started + 1] = {task = task, callback = callback}; return true
    end, cancel = function() worker_cancelled = worker_cancelled + 1 end} end}
end
local Gateway = require('weread.ui.gateway_book_reviews')
local info
local host = {settings = {}, client = {}, library_db = {accountKey = function() return account end},
    _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}},
    showBusy = function(self, _, cancel) self.busy_message = {}; self.cancel_busy = cancel end,
    closeBusy = function(self) self.busy_message = nil end,
    showInfo = function(_, message) info = message end,
    runOnlineTask = function(_, _, callback) pending[#pending + 1] = callback; return true end,
    showBookReviewDetail = function(self, _, review, mode, options)
        self.selected = review; return {mode = mode, options = options}
    end}
local book = {book_id = '42', title = 'Book'}
local function schedule() table.remove(pending, 1)() end
local function tick() local job = table.remove(started, 1); job.callback(job.task()) end
local checks = 0
local function expect(v, message) checks = checks + 1; assert(v, message) end
expect(Gateway.open(host, book, selected), 'gateway owner did not open')
expect(#pending == 1 and #started == 0 and #requests == 0, 'network was not scheduled')
schedule(); expect(#started == 1 and #requests == 0, 'network ran outside worker')
tick(); local first = views[#views]
expect(first.data.mode == 'recommended' and #requests == 1 and not host.busy_message, 'first page failed')
first.callbacks.on_select(first.result.items[1], 'recommended')
local detail = assert(host._gateway_reviews_owner.detail)
expect(type(detail.options.on_replies) == 'function', 'same-owner native replies unavailable')
detail.options.on_replies(); expect(replies_opened == 1, 'reply entry failed')
detail.options.on_close(); expect(replies_cancelled == 1 and not host._gateway_reviews_owner.detail, 'detail close leaked replies')
detail.options.on_replies(); expect(replies_opened == 1, 'closed detail reopened replies')
first.callbacks.on_load_more(); schedule(); tick()
local second = views[#views]
expect(#second.result.items == 2 and requests[2].previous == first.result and first._review_closed, 'continuation failed')
second.callbacks.on_switch('latest'); schedule(); tick()
local latest = views[#views]
expect(latest.data.mode == 'latest' and requests[3].mode == 'latest', 'latest mode failed')
latest.callbacks.on_switch('recommended')
local cached = views[#views]
expect(#requests == 3 and #cached.result.items == 2, 'mode cache refetched or lost results')
source_error = 'failure'; cached.callbacks.on_load_more(); schedule(); tick(); source_error = nil
expect(host._gateway_reviews_owner.view == cached and info == 'Could not load book reviews. Please try again.', 'failure lost old page')
cached.callbacks.on_load_more(); schedule(); host.cancel_busy(); tick()
expect(host._gateway_reviews_owner.view == cached and #views == 4, 'cancelled continuation reopened view')
Gateway.cancel(host)
expect(not host._gateway_reviews_owner and worker_cancelled > 0, 'owner not closed')
Gateway.open(host, book, selected); schedule(); account = 'b'; tick(); account = 'a'
expect(not host._gateway_reviews_owner and #views == 4, 'result crossed account')
Gateway.open(host, book, selected); schedule(); source_valid = false; tick(); source_valid = true
expect(not host._gateway_reviews_owner and #views == 4, 'result crossed credentials')
source_valid = false; Gateway.open(host, book, selected); source_valid = true
expect(not host._gateway_reviews_owner and #pending == 0, 'stale initial authorization left an orphaned owner')
Gateway.open(host, book, selected); schedule(); host._book_detail_view = {}; tick()
expect(not host._gateway_reviews_owner and #views == 4, 'result outlived book detail')
local key_only = {api_key = 'synthetic', key_only = true}
account = nil; expect(Gateway.open(host, book, key_only), 'legacy key-only owner rejected')
schedule(); tick(); local legacy = views[#views]
legacy.callbacks.on_select(legacy.result.items[1], 'recommended')
expect(not host._gateway_reviews_owner.detail.options.on_replies, 'key-only review exposed native replies')
Gateway.cancel(host); account = 'a'
print('gateway_book_reviews_ui_spec: ' .. checks .. ' checks')
