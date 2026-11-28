package.path = './?.lua;' .. package.path
local pending, started, views = {}, {}, {}
local source_valid, source_error, account = true, nil, 'a'
local snapshots, native_fallbacks = {}, 0
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
package.preload['weread.lib.plugin_util'] = function()
    return {tr = function(v) return v end, T = function(pattern) return pattern end}
end
package.preload['weread.lib.native_book_reviews_cache'] = function() return {new = function(_self, _library, _codec, owner, mode)
    local key=owner..':'..(mode or 'native')
    return {write=function(_, id, page, now)
        assert(id=='42')
        if snapshots[key] and page.has_more and #snapshots[key].items>#page.items then return end
        snapshots[key]={items=page.items,mode=mode,saved_at=now,has_more=page.has_more}
    end,read=function(_, id)
        assert(id=='42')
        local copy={}
        if not snapshots[key] then return nil end
        for k,v in pairs(snapshots[key]) do copy[k]=v end
        return copy
    end}
end} end
package.preload['weread.ui.native_book_reviews']=function() return {open=function(_, _, selected_source)
    assert(not selected_source);native_fallbacks=native_fallbacks+1
end} end
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
local function tick(frame)
    local job = table.remove(started, 1)
    job.callback(frame or job.task())
end
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
cached.callbacks.on_load_more(); schedule(); host.cancel_busy(); tick({ok=true,page=cached.result})
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
local before_offline=#requests
expect(Gateway.open(host,book),'offline account could not open saved reviews')
expect(#pending==0 and #started==1,'offline review opening scheduled a network task')
tick();local saved=views[#views]
expect(saved.data.mode=='recommended' and saved.result.saved_at and #saved.result.items==2
    and not saved.result.has_more and saved.data.incomplete_text,'offline view restored the wrong results or a network cursor')
saved.callbacks.on_switch('latest');tick()
local saved_latest=views[#views]
expect(saved_latest.data.mode=='latest' and #saved_latest.result.items==1 and #requests==before_offline,
    'offline second tab requested HTTP or loaded the wrong snapshot')
local count=#views
saved.callbacks.on_select(saved.result.items[1],'recommended')
expect(not host._gateway_reviews_owner.detail,'closed offline review page opened a detail')
Gateway.cancel(host)
Gateway.open(host,book);account='b';tick();account='a'
expect(not host._gateway_reviews_owner and #views==count,'cached review result crossed accounts')
Gateway.open(host,book,selected);schedule();source_error='gateway_reviews/unavailable';tick();tick();source_error=nil
expect(views[#views].result.saved_at and #views[#views].result.items==2,'network failure did not fall back to Skill cache')
Gateway.cancel(host);snapshots['a:recommended']=nil
Gateway.open(host,book);tick()
expect(views[#views].data.mode=='latest','only saved latest reviews could not open on cold start')
Gateway.cancel(host);snapshots['a:latest']=nil
Gateway.open(host,book);tick()
expect(native_fallbacks==1 and not host._gateway_reviews_owner,'offline cache miss did not hand off to native latest reviews')

local original_fetch=source.fetch
source.fetch=function(client,id,mode,previous,access)
    if mode=='latest' then
        requests[#requests+1]={mode=mode}
        return {items={},has_more=false}
    end
    return original_fetch(client,id,mode,previous,access)
end
local native_requests,native_error={},nil
local native_source=require('weread.lib.native_book_reviews_source')
native_source.fetch=function(_,id,limit,previous,access,recover)
    assert(id=='42' and access==selected)
    native_requests[#native_requests+1]={limit=limit,previous=previous,recover=recover}
    if native_error then error(native_error,0) end
    local ids,items={},{}
    for i=1,limit do
        ids[i]='native-'..i
        items[i]={review_id=ids[i],author='Reader',content='Native review',rating=5,create_time=1700000000-i}
    end
    return {items=items,ids=ids,limit=limit,has_more=limit<40}
end
local function begin_mixed()
    expect(Gateway.open(host,book,selected),'combined review owner did not open')
    schedule();tick()
    local recommended=views[#views]
    recommended.callbacks.on_switch('latest');schedule();tick()
    expect(host._gateway_reviews_owner.view==recommended and #started==1,'empty Skill result replaced the visible tab')
    return recommended
end
begin_mixed();tick()
local mixed_latest=views[#views]
expect(mixed_latest.data.mode=='latest' and #mixed_latest.result.items==20 and mixed_latest.result.items[1].review_id=='native-1',
    'native latest did not replace the empty first page')
local skill_calls=#requests
mixed_latest.callbacks.on_load_more();schedule();tick()
local mixed_more=views[#views]
expect(#mixed_more.result.items==40 and not mixed_more.result.has_more and #requests==skill_calls
    and native_requests[2].limit==40 and native_requests[2].previous==mixed_latest.result.ids,
    'native continuation reused Skill pagination or lost its prefix')
mixed_more.callbacks.on_switch('recommended')
expect(views[#views].result.items[1].review_id=='recommended-1','native latest replaced the recommendation cache')
views[#views].callbacks.on_switch('latest')
expect(#views[#views].result.items==40 and #native_requests==2 and #requests==skill_calls,'tab switch fetched or lost the cached native list')
Gateway.cancel(host)

Gateway.open(host,book);tick();views[#views].callbacks.on_switch('latest');tick()
expect(views[#views].data.mode=='latest' and #views[#views].result.items==40 and not views[#views].result.has_more
    and #requests==skill_calls and #native_requests==2,'offline latest did not read the native cache')
Gateway.cancel(host)

snapshots['a:native']=nil
native_error='native_reviews/unavailable'
begin_mixed();tick();tick()
expect(views[#views].data.mode=='latest' and #views[#views].result.items==0 and not host.busy_message,
    'unavailable native fallback hid the valid empty response')
views[#views].callbacks.on_switch('recommended')
expect(views[#views].result.items[1].review_id=='recommended-1','failed fallback detached recommendations')
Gateway.cancel(host)
native_error=nil
begin_mixed();host.cancel_busy();tick()
expect(host._gateway_reviews_owner.view.data.mode=='recommended','cancelled native fallback switched the tab')
Gateway.cancel(host)
local renewal_callback
selected.base_revision='same-skill-account'
local scope=selected.native.scope
host.settings.auth_scope_matches=function(_,candidate) return candidate==scope end
source.capture=function() return selected end
host.native_renewal={start=function(_,options,callback)
    assert(options.expected_revision==1)
    renewal_callback=callback
    return true,{}
end,cancel=function() end}
native_error='native_reviews/native_expired'
begin_mixed();tick()
expect(renewal_callback and host._gateway_reviews_owner.context.renewing
    and native_requests[#native_requests].recover,'native latest did not enter owned renewal')
selected={api_key=selected.api_key,base_revision=selected.base_revision,native={scope=scope,revision=3}}
native_error=nil;renewal_callback(true);tick()
expect(views[#views].data.mode=='latest' and #views[#views].result.items==20
    and native_requests[#native_requests].recover==false,'verified renewal lost or repeated the native latest request')
Gateway.cancel(host)
print('gateway_book_reviews_ui_spec: ' .. checks .. ' checks')
