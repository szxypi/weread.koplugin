package.path = './?.lua;' .. package.path
local pending, started, views, closed = {}, {}, {}, 0
local source_error, valid, recovery_callback, allow_recovery = nil, true, nil, false
local selected = {native = {scope = {vid = '123'}, revision = 1}}
local source = {capture = function() return selected end, matches = function(_, value) return valid and value == selected end}
source.fetch_replies = function(_, book, review, limit, previous, access)
    assert(book == '42' and review == 'review_1' and access == selected)
    if source_error then error(source_error, 0) end
    local items, ids = {}, {}
    for i = 1, limit do
        ids[i] = 'reply_' .. i
        items[i] = {review_id = ids[i], author = 'Reader', content = 'Reply ' .. i, rating = 0, create_time = 1700000000}
    end
    if previous then for i, id in ipairs(previous) do assert(id == ids[i]) end end
    return {items = items, ids = ids, limit = limit, has_more = limit < 40}
end
package.preload['weread.lib.native_book_reviews_source'] = function() return source end
package.preload['weread.lib.native_read_recovery'] = function()
    return {cancel = function() end, current = function() return true end,
        start = function(_, context, _, options)
            if not allow_recovery then return false end
            context.renewing = true
            recovery_callback = function(success) context.renewing = false; options.complete(success, selected) end
            return true
        end}
end
package.preload['weread.lib.plugin_util'] = function() return {tr = function(v) return v end} end
package.preload['ui/widget/textviewer'] = function() return {new = function(_, value) return value end} end
package.preload['ui/uimanager'] = function()
    return {show = function() end, close = function(_, view)
        closed = closed + 1
        if view.callbacks then view.callbacks.on_close() end
    end}
end
package.preload['weread.ui.book_reviews_view'] = function()
    return {show = function(data, callbacks)
        local view = {data = data, result = data.result, callbacks = callbacks}; views[#views + 1] = view; return view
    end}
end
package.preload['weread.lib.memory_worker'] = function()
    return {new = function() return {start = function(_, task, callback)
        started[#started + 1] = {task = task, callback = callback}; return true
    end, cancel = function() end} end}
end
local Replies = require('weread.ui.native_review_replies')
local info, current = nil, true
local parent = {selected = selected, detail = {}}
local host = {settings = {}, client = {}, _native_reviews_owner = parent,
    showBusy = function(self, _, cancel) self.busy_message = {}; self.cancel_busy = cancel end,
    closeBusy = function(self) self.busy_message = nil end,
    showInfo = function(_, value) info = value end,
    runOnlineTask = function(_, _, fn) pending[#pending + 1] = fn; return true end}
local book, review = {book_id = '42', title = 'Book'}, {review_id = 'review_1'}
local function parent_current() return current end
local function open() return Replies.open(host, parent, book, review, parent.detail, parent_current) end
local function schedule() table.remove(pending, 1)() end
local function tick() local job = table.remove(started, 1); job.callback(job.task()) end
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
expect(open(), 'reply UI did not open'); schedule(); tick()
local first = views[#views]
expect(first.data.title_text == 'Review replies' and #first.result.items == 20 and first.result.has_more,
    'first page did not render')
first.callbacks.on_select(first.result.items[1])
expect(host._native_review_replies_owner.viewer.text:find('Reply 1', 1, true), 'long reply viewer did not open')
host._native_review_replies_owner.viewer.close_callback()
first.callbacks.on_load_more(); schedule(); tick()
expect(#views[#views].result.items == 40 and not views[#views].result.has_more and closed > 0, 'pagination failed')
views[#views].callbacks.on_close(); expect(not host._native_review_replies_owner, 'close did not cancel owner')
open(); schedule(); host.cancel_busy(); tick()
expect(not host._native_review_replies_owner and #views == 2, 'cancelled result reopened')
open(); schedule(); current = false; tick(); current = true
expect(not host._native_review_replies_owner and #views == 2, 'reply crossed parent scope')
open(); schedule(); valid = false; tick(); valid = true
expect(not host._native_review_replies_owner and #views == 2, 'reply crossed credentials')
open(); schedule(); tick(); first = views[#views]
source_error = 'review_replies/changed'; first.callbacks.on_load_more(); schedule(); tick()
expect(host._native_review_replies_owner.view == first and info == 'Review replies changed. Close and open them again.',
    'changed prefix lost old page')
source_error = nil; Replies.cancel(host)
allow_recovery = true; host.native_renewal = {}; source_error = 'native_reviews/native_expired'
open(); schedule(); tick()
expect(recovery_callback and host._native_review_replies_owner.context.renewing, '401 did not start renewal')
source_error = nil; recovery_callback(true); tick()
expect(host._native_review_replies_owner.view ~= nil, 'successful renewal did not retry')
Replies.cancel(host)
expect(not Replies.open(host, parent, book, {review_id = 'bad id'}, parent.detail, parent_current), 'invalid id accepted')
print('native_review_replies_ui_spec: ' .. checks .. ' checks')
