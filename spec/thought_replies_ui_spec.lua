package.path = './?.lua;' .. package.path
local pending, started = {}, {}
local valid, visible, native_available, store_reads, opens, cancels, infos = true, true, true, 0, 0, 0, {}
local fallback_store
local selected = {native = {scope = {vid = '123'}}}
package.preload['weread.lib.native_book_reviews_source'] = function()
    return {capture = function() return native_available and selected or nil end,
        matches = function(_, value) return valid and value == selected end}
end
package.preload['weread.lib.plugin_util'] = function() return {tr = function(value) return value end} end
package.preload['weread.lib.annotation_store'] = function() return {new = function() return fallback_store end} end
package.preload['ui/uimanager'] = function() return {isWidgetShown = function() return visible end,
    scheduleIn=function(_self,_delay,callback) pending[#pending+1]=callback end} end
package.preload['weread.lib.memory_worker'] = function()
    return {new = function() return {start = function(_, task, callback)
        started[#started + 1] = {task = task, callback = callback}; return true
    end, cancel = function() end} end}
end
package.preload['weread.ui.native_review_replies'] = function()
    return {open = function(host, parent, book, review, detail, current, options)
        assert(book.book_id == '42' and review.review_id == 'r2' and parent.detail == detail
            and current() and options.review_type == 1)
        opens = opens + 1; host._native_review_replies_owner = {parent = parent}; return true
    end, cancel = function(host) cancels = cancels + 1; host._native_review_replies_owner = nil end}
end
local Annotations = require('weread.lib.annotations')
local row = {range = '10-20', pageReviews = {
    {reviewId = 'r1', review = {reviewId = 'r1', bookId = '42', chapterUid = 7, type = 1,
        author = {name = 'A'}, content = 'one'}},
    {reviewId = 'r2', review = {reviewId = 'r2', bookId = '42', chapterUid = 7, type = 1,
        author = {name = 'B'}, content = 'two'}},
}}
local source = {book_id = '42', chapter_uid = '7', reviews = {row}}
local items = Annotations.buildThoughtPopupItems(row)
local popup = {items = items}
local store = {get = function(_, book, kind, chapter)
    store_reads = store_reads + 1; assert(book == '42' and kind == 'source' and chapter == '7'); return source
end}
fallback_store = store
local context = {book_id = '42', store = store}
local host = {settings = {}, client = {}, library_db = {accountKey = function() return 'a' end},
    ui = {document = {}}, _reader_session_gen = 1, discovery_epoch = 1, _annotation_context = context,
    showBusy = function(self, _, cancel) self.busy_message = {}; self.cancel_busy = cancel end,
    closeBusy = function(self) self.busy_message = nil end,
    showInfo = function(_, value) infos[#infos + 1] = value end,
    runOnlineTask = function(_, _, callback) pending[#pending + 1] = callback; return true end}
local Replies = require('weread.ui.thought_replies')
local info = {book_id = '42', chapter_uid = '7', range = '10-20'}
local function schedule() table.remove(pending, 1)() end
local function tick() local job = table.remove(started, 1); job.callback(job.task()) end
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
expect(Replies.open(host, info, items, items[2], popup), 'thought reply did not start')
expect(store_reads == 0 and #pending == 1, 'source read ran before scheduling')
schedule(); expect(store_reads == 0 and #started == 1, 'source read ran outside worker')
tick(); expect(opens == 1 and store_reads == 1 and not host.busy_message, 'verified reply did not open')
Replies.cancelForPopup(host, {}); expect(cancels == 0, 'other popup cancelled reply')
Replies.cancelForPopup(host, popup); expect(cancels == 1 and not host._thought_reply_owner, 'closing popup did not cancel reply')
Replies.open(host, info, items, items[2], popup); schedule(); host.cancel_busy(); tick()
expect(opens == 1 and not host._thought_reply_owner, 'cancelled resolver opened replies')
Replies.open(host, info, items, items[2], popup); schedule(); valid = false; tick(); valid = true
expect(opens == 1 and not host._thought_reply_owner, 'stale authorization opened replies')
Replies.open(host, info, items, items[2], popup); schedule(); popup.items = {}; tick(); popup.items = items
expect(opens == 1 and not host._thought_reply_owner, 'recycled popup opened stale replies')
Replies.open(host, info, items, items[2], popup); schedule(); items[2].content = 'changed'; tick(); items[2].content = 'two'
expect(opens == 1 and not host._thought_reply_owner, 'mutated displayed thought opened stale replies')
Replies.open(host, info, items, items[2], popup); schedule(); row.pageReviews[2].review.reviewId = 'other'; tick()
row.pageReviews[2].review.reviewId = 'r2'
expect(opens == 1 and infos[#infos] == 'Could not match this thought. Refresh the chapter and try again.', 'mismatched source was accepted')
host._annotation_context = nil
expect(Replies.open(host, info, items, items[2], popup), 'legacy popup could not use the saved source')
schedule(); tick(); expect(opens == 2, 'legacy popup did not resolve the saved source')
Replies.cancel(host); host._annotation_context = context
native_available = false
host.runOnlineTask=function() error('local thought matching requested network') end
expect(Replies.open(host, info, items, items[2], popup),'saved thought could not open without native grant')
schedule();tick();expect(opens==3,'saved thought was not matched without network or authorization')
Replies.cancel(host)
native_available = true; visible = false
expect(not Replies.open(host, info, items, items[2], popup), 'closed popup accepted action')
print('thought_replies_ui_spec: ' .. checks .. ' checks')
