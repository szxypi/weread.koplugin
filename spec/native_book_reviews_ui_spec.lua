package.path = './?.lua;' .. package.path
local pending, started, views, failures, cancellations, closes = {}, {}, {}, 0, 0, 0
local access_valid, source_error = true, nil
local allow_recovery, recovery_callback = false, nil
local reply_opens, reply_cancels = 0, 0
local saved_reviews,cache_writes,cache_reads,fetch_calls=nil,0,0,0
package.preload['weread.lib.native_book_reviews_cache']=function() return {validate=function(_codec,page)
    assert(type(page)=='table' and type(page.items)=='table');return page
end,new=function()
    return {write=function(_self,_id,page) cache_writes=cache_writes+1;saved_reviews=page;return true end,
        read=function() cache_reads=cache_reads+1;if not saved_reviews then return nil end
            return {items=saved_reviews.items,ids=saved_reviews.ids,limit=saved_reviews.limit,saved_at=1000,
                has_more=saved_reviews.has_more,limited=false} end}
end} end
local selected = {native = {scope = {vid = '123'}, revision = 1}}
local source = {capture = function() return selected end, matches = function(_, value) return access_valid and value == selected end}
source.fetch = function(_, book, limit, previous, value)
    assert(book == '42' and value == selected)
    fetch_calls = fetch_calls + 1
    if source_error then error(source_error, 0) end
    local items, ids = {}, {}
    for i = 1, limit do items[i] = {review_id = 'r' .. i, rating = i % 2 == 0 and 5 or 4}; ids[i] = 'r' .. i end
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
package.preload['weread.lib.plugin_util'] = function() return {tr = function(v) return v end,
    T=function(value,arg) return value:gsub('%%1',arg) end} end
package.preload['weread.ui.native_review_replies'] = function()
    return {open = function() reply_opens = reply_opens + 1 end, cancel = function() reply_cancels = reply_cancels + 1 end}
end
package.preload['ui/uimanager'] = function()
    return {close = function(_, view) closes = closes + 1; view.callbacks.on_close() end}
end
package.preload['weread.ui.book_reviews_view'] = function()
    return {show = function(data, callbacks)
        local view = {data = data, result = data.result, callbacks = callbacks}; views[#views + 1] = view; return view
    end}
end
package.preload['weread.lib.memory_worker'] = function()
    return {new = function() return {start = function(_, task, callback)
        started[#started + 1] = {task = task, callback = callback}; return true
    end, cancel = function() cancellations = cancellations + 1 end} end}
end
local UI = require('weread.ui.native_book_reviews')
local account, info, auth_epoch = 'a', 0, 1
local online=true
local host = {library_db = {accountKey = function() return account end}, settings = {get=function(_self,key,default)
        return key=='auth_epoch' and auth_epoch or default end}, client = {},
    _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}},
    showBusy = function(self, _, cancel) self.busy_message = {}; self.cancel_busy = cancel end,
    closeBusy = function(self) self.busy_message = nil end,
    showInfo = function(self, message) info = info + 1; self.last_info = message end,
    isNetworkConnected = function() return online end,
    isNetworkOnline = function() error('latest reviews probed the Internet on the UI thread') end,
    runOnlineTask = function(_, _, callback, _, options)
        assert(options.link_only and options.silent_offline)
        pending[#pending + 1] = callback; return true
    end,
    showBookReviewDetail = function(self, _, review, _, options)
        self.selected_review = review; return {options = options}
    end}
local function schedule() table.remove(pending, 1)() end
local function tick()
    local job = table.remove(started, 1); job.callback(job.task())
end
local checks = 0
local function expect(value, message) checks = checks + 1; if not value then failures = failures + 1; error(message) end end
expect(UI.open(host, {book_id = '42', title = 'Book'}, selected), 'open failed')
expect(#pending == 1 and #started == 0, 'request did not wait for scheduler')
schedule(); expect(#started == 1 and #views == 0, 'network did not run in worker')
tick(); expect(#views == 1 and views[1].data.latest_only and not host.busy_message, 'latest reviews not shown')
views[1].callbacks.on_select(views[1].data.result.items[1]); expect(host.selected_review.review_id == 'r1', 'selection failed')
local detail = host._native_reviews_owner.detail
detail.options.on_replies(); expect(reply_opens == 1, 'review detail did not open replies')
detail.options.on_close(); expect(reply_cancels == 1 and not host._native_reviews_owner.detail, 'detail did not close replies')
detail.options.on_replies(); expect(reply_opens == 1, 'closed detail reopened replies')
views[1].callbacks.on_load_more(); schedule(); tick()
expect(#views == 2 and closes == 1 and #views[2].data.result.items == 40 and not views[2].data.result.has_more,
    'more reviews did not preserve first page')
views[2].callbacks.on_close(); expect(not host._native_reviews_owner and cancellations == 1, 'closing did not cancel owner')
-- Late results cannot reopen after cancel or account switch.
UI.open(host, {book_id = '42'}, selected); schedule(); host.cancel_busy(); tick()
expect(#views == 2 and not host._native_reviews_owner, 'cancelled request rendered')
UI.open(host, {book_id = '42'}, selected); schedule(); account = 'b'; tick()
expect(#views == 2 and not host._native_reviews_owner, 'request crossed accounts')
account = 'a'; UI.open(host, {book_id = '42'}, selected); schedule(); host._book_detail_view = {}; tick()
expect(#views == 2 and not host._native_reviews_owner, 'request outlived book detail')
UI.open(host, {book_id = '42'}, selected); schedule(); access_valid = false; tick()
expect(#views == 2 and not host._native_reviews_owner, 'request outlived authorization')
access_valid = true; UI.open(host, {book_id = '42'}, selected); schedule(); tick()
local current_view = views[#views]
source_error = 'native_reviews/changed'; current_view.callbacks.on_load_more(); schedule(); tick()
expect(host._native_reviews_owner.view == current_view and host.last_info == 'Book reviews changed. Close and open them again.',
    'changed prefix lost the prior page or omitted the refresh guidance')
source_error = nil; UI.cancel(host)
allow_recovery = true; host.native_renewal = {}; source_error = 'native_reviews/native_expired'
UI.open(host, {book_id = '42'}, selected); schedule(); tick()
expect(recovery_callback and host._native_reviews_owner.context.renewing, 'expired authorization did not start recovery')
source_error = nil; recovery_callback(true); tick()
expect(host._native_reviews_owner.view ~= nil, 'successful renewal did not retry the read')
UI.cancel(host)
expect(not UI.open(host, {book_id = 'CB_fake/invalid'}, selected) and info == 2, 'unsupported ID accepted')
saved_reviews={items={{review_id='saved'}},ids={'saved'},limit=20,has_more=true}
online=false;local before_pending=#pending;local before_views=#views
expect(UI.open(host,{book_id='42',title='Book'},nil),'offline cache did not open')
expect(#pending==before_pending and #started==1,'offline cache attempted network scheduling')
tick();local cached=views[#views]
expect(#views==before_views+1 and cached.data.tab_text=='Saved latest reviews'
    and cached.data.incomplete_text:find('reviews may be incomplete.',1,true) and not cached.result.has_more,
    'saved reviews lacked offline scope or offered remote pagination')
cached.callbacks.on_select(cached.result.items[1]);detail=host._native_reviews_owner.detail
expect(host.selected_review.review_id=='saved' and detail.options.on_replies,'saved review did not offer saved replies')
detail.options.on_replies();expect(reply_opens==2,'saved review did not open its reply view')
detail.options.on_close();UI.cancel(host)
online=true;source_error='native_reviews/unavailable';UI.open(host,{book_id='42'},selected);schedule();tick()
expect(host._native_reviews_owner.context and #started==1,'failed initial read did not check cached reviews')
tick();expect(views[#views].data.tab_text=='Saved latest reviews','network failure did not show saved reviews')
source_error=nil;UI.cancel(host)
local original_schedule=host.runOnlineTask
host.runOnlineTask=function() return false end
before_views=#views;UI.open(host,{book_id='42'},selected);tick()
expect(#views==before_views+1 and views[#views].data.tab_text=='Saved latest reviews',
    'network loss during scheduling did not fall back to cached reviews')
host.runOnlineTask=original_schedule;UI.cancel(host)
online=false;before_views=#views;UI.open(host,{book_id='42'},nil);host.cancel_busy();tick()
expect(#views==before_views and not host._native_reviews_owner,'cancelled cache read reopened reviews')
UI.open(host,{book_id='42'},nil);account='b';tick();account='a'
expect(#views==before_views and not host._native_reviews_owner,'cache read crossed accounts')
UI.open(host,{book_id='42'},nil);auth_epoch=2;tick();auth_epoch=1
expect(#views==before_views and not host._native_reviews_owner,'cache read crossed a same-account login change')
saved_reviews=nil;UI.open(host,{book_id='42'},nil);tick()
expect(not host._native_reviews_owner and host.last_info=='No saved book reviews. Connect and try again.',
    'missing offline cache was not explained')
expect(cache_writes>0 and cache_reads>=4,'review cache was not used')
online=true;source_error=nil
expect(UI.open(host,{book_id='42',title='Book'},selected),'filter review open failed');schedule();tick()
local latest=views[#views];local calls,writes=fetch_calls,cache_writes
expect(latest.data.mode=='latest' and latest.data.native_filters and #latest.result.items==20,'latest filter missing')
host.runOnlineTask=function() return false end
latest.callbacks.on_load_more()
expect(host._native_reviews_owner.view==latest and #started==0 and not host.busy_message,
    'link loss during pagination replaced the visible reviews or read another cache')
host.runOnlineTask=original_schedule
latest.callbacks.on_switch('five_stars')
local filtered=views[#views]
expect(filtered~=latest and filtered.data.mode=='five_stars' and #filtered.result.items==10
    and filtered.result.items[1].review_id=='r2' and filtered.result.has_more
    and filtered.data.incomplete_text=='Only loaded reviews are filtered; more may be available.',
    'five-star view did not filter only loaded results')
expect(fetch_calls==calls and cache_writes==writes and #pending==0,'local filter fetched or saved data')
latest.callbacks.on_load_more();latest.callbacks.on_select(latest.result.items[1]);latest.callbacks.on_switch('latest')
expect(#pending==0 and not host._native_reviews_owner.detail and views[#views]==filtered,'stale review view acted')
filtered.callbacks.on_select(filtered.result.items[1]);expect(host.selected_review.review_id=='r2','filtered review did not open')
detail=host._native_reviews_owner.detail;filtered.callbacks.on_switch('latest')
expect(views[#views]==filtered,'filter switched while review detail was open')
detail.options.on_close();filtered.callbacks.on_load_more();schedule();tick()
local more=views[#views]
expect(more.data.mode=='five_stars' and #more.result.items==20 and more.result.items[20].review_id=='r40'
    and not more.result.has_more,'filtered pagination did not extend raw results')
more.callbacks.on_switch('latest');latest=views[#views]
expect(latest.data.mode=='latest' and #latest.result.items==40,'switching back lost loaded results')
UI.cancel(host);online=false
expect(UI.open(host,{book_id='42',title='Book'},nil),'offline filtered reviews did not open');tick()
local saved=views[#views];saved.callbacks.on_switch('five_stars');filtered=views[#views]
expect(filtered.data.mode=='five_stars' and #filtered.result.items==20 and not filtered.result.has_more
    and filtered.data.incomplete_text:find('only loaded reviews are filtered.',1,true),
    'offline filter lost cached results or scope notice')
UI.cancel(host)
online=true
source.fetch=function(_,book,limit,previous,value)
    assert(book=='CB_Imported' and limit==20 and not previous and value==selected)
    return {items={{review_id='imported-review',rating=5}},ids={'imported-review'},limit=20,has_more=false}
end
expect(UI.open(host,{bookId='CB_Imported',title='Imported'},selected),'imported public reviews did not open')
schedule();tick()
local imported=views[#views]
imported.callbacks.on_select(imported.result.items[1]);detail=host._native_reviews_owner.detail
expect(host.selected_review.review_id=='imported-review' and detail.options.on_replies==nil,
    'imported public review unexpectedly enabled unverified replies')
print('native_book_reviews_ui_spec: ' .. checks .. ' checks')
