-- Private input, native UI and bounded read-only HTTPS; no screenshots or real data files.
require('ffi').log = function() end
require('setupkoenv')
local cache_mode=os.getenv('WEREAD_REPLY_CACHE_MODE')
local home=os.getenv('KO_HOME')
package.path = (cache_mode and assert(home)..'/plugins/weread.koplugin' or '/source') .. '/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):wrap({language = 'zh_CN'})
require('gettext').changeLang('zh_CN')
local json, ffi = require('json'), require('ffi')
local input = json.decode(assert(io.read('*a')))
pcall(ffi.cdef, 'void *mmap(void *, unsigned long, int, int, int, long);')
local memory = ffi.C.mmap(nil, 4096, 3, 0x21, -1, 0)
assert(memory ~= ffi.cast('void *', -1))
local counter = ffi.cast('int *', memory); counter[0] = 0
local phase, painted, heartbeat = 'setup', false, false
local ok = pcall(function()
    local Device = require('device'); require('document/canvascontext'):init(Device)
    Device.screen.shot = function() error('screenshots_disabled', 0) end
    local UI, socket = require('ui/uimanager'), require('socket')
    local grant, book, review = input.credentials, assert(input.book_id), assert(input.review_id)
    local vid=assert(input.vid or grant and grant.vid)
    if cache_mode~='offline' then assert(grant) end
    assert(type(book) == 'string' and book:match('^[1-9]%d*$') and #book <= 20)
    local Protocol = require('weread.lib.protocol')
    local review_url = 'https://i.weread.qq.com/review/list?bookId=' .. book
        .. '&listType=3&listMode=1&synckey=0&count='
    local replies_url = 'https://i.weread.qq.com/review/single?reviewId=' .. Protocol.urlencode(review)
        .. '&commentsCount='
    local expected = {review_url .. '21&maxIdx=0&tips=1', review_url .. '41&maxIdx=0&tips=1',
        review_url .. '61&maxIdx=0&tips=1', replies_url .. '21&commentsDirection=0&likesCount=0&synckey=0',
        replies_url .. '41&commentsDirection=0&likesCount=0&synckey=0'}
    local scope = {vid = vid, epoch = 1}
    local store = {read = function() return grant, 1, nil, false end}
    local settings = {data_dir = cache_mode and home or '/unused', get = function(_, key, fallback)
        if cache_mode and key=='account' then return {user_vid=vid} end
        return fallback
    end,
        get_auth_scope = function() return scope end, auth_scope_matches = function(_, value) return value == scope end}
    local Client = require('weread.lib.client')
    local client = Client:new(settings)
    local original = client.request
    client.request = function(self, options)
        assert(cache_mode~='offline' and counter[0] < #expected and options.url == expected[counter[0] + 1] and options.method == 'GET'
            and not options.body and options.sensitive and options.skip_cookie and not options.persist_response_cookies)
        counter[0] = counter[0] + 1
        return original(self, options)
    end
    local Source = require('weread.lib.native_book_reviews_source')
    local ReviewModel = require('weread.lib.native_book_reviews')
    local ReplyModel = require('weread.lib.native_review_replies')
    local Reviews = require('weread.ui.native_book_reviews')
    local selected
    if cache_mode~='offline' then selected=assert(Source.capture(settings, store)) end
    local library=cache_mode and require('weread.lib.library_db'):new(settings)
        or {accountKey = function() return 'volatile-account' end}
    local host = {settings = settings, client = client, library_db = library,
        _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}}}
    function host:isNetworkConnected() return cache_mode~='offline' end
    function host:isNetworkOnline() error('replies used synchronous Internet reachability',0) end
    function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
    function host:closeBusy() self.busy_message = nil end
    function host:showInfo() error('review_ui_failed', 0) end
    function host:runOnlineTask(_, fn, _delay, options)
        assert(options.link_only and options.silent_offline)
        UI:scheduleIn(0.01, fn); return true
    end
    host.showBookReviewDetail = require('weread.ui.library').showBookReviewDetail
    local function wait(predicate)
        local deadline = socket.gettime() + 30
        while not predicate() do
            UI:setInputTimeout(0); UI:handleInput(); socket.sleep(0.01)
            assert(socket.gettime() < deadline)
        end
    end
    local function compare(actual, wanted)
        assert(#actual.items == #wanted.items and actual.has_more == wanted.has_more)
        for index, item in ipairs(actual.items) do
            local other = wanted.items[index]
            for _, field in ipairs({'review_id', 'author', 'content', 'rating', 'create_time', 'is_finish'}) do
                assert(item[field] == other[field])
            end
        end
    end
    local function prefix(n)
        local rows = client:json_decode('[]')
        for i = 1, math.min(n, #input.listing.reviews) do rows[i] = input.listing.reviews[i] end
        return {reviews = rows}
    end
    UI:setRunForeverMode(); UI:setInputTimeout(0)
    phase = 'book_first'
    assert(Reviews.open(host, {book_id = book, title = '微信读书'}, selected))
    UI:scheduleIn(0.05, function() heartbeat = true end)
    wait(function() return host._native_reviews_owner and host._native_reviews_owner.view ~= nil end)
    local view = host._native_reviews_owner.view
    if cache_mode=='offline' then
        phase='offline_reviews'
        local expected_reviews=ReviewModel.project(client,prefix(61),book,60)
        expected_reviews.has_more=false;compare(view.result,expected_reviews)
        assert(view.tab_text=='Saved latest reviews' and view.result.items[input.review_index].review_id==review)
        view._review_buttons[input.review_index].callback()
        local detail=assert(host._native_reviews_owner.detail);detail.buttons_table[1][1].callback()
        wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
        local replies=host._native_review_replies_owner.view
        local first=ReplyModel.project(client,input.first,book,review,20)
        local second=ReplyModel.project(client,input.second,book,review,40,first.ids)
        second.has_more=false;compare(replies.result,second)
        assert(replies.tab_text=='Saved replies' and #replies.result.items>0)
        replies._review_buttons[1].callback()
        local reply=assert(host._native_review_replies_owner.viewer)
        assert(reply.text:find(second.items[1].content,1,true));reply:onClose()
        UI:forceRePaint();painted=true;replies:onClose();detail:onClose();view:onClose()
        assert(not host._native_review_replies_owner and not host._native_reviews_owner and counter[0]==0)
        phase='complete';return
    end
    local wanted = ReviewModel.project(client, prefix(21), book, 20)
    compare(view.result, wanted)
    for _, limit in ipairs({40, 60}) do
        phase = 'book_more_' .. limit
        assert(view.result.has_more)
        view._review_buttons[#view._review_buttons].callback()
        local previous = view
        wait(function() return host._native_reviews_owner and host._native_reviews_owner.view ~= previous end)
        view = host._native_reviews_owner.view
        wanted = ReviewModel.project(client, prefix(limit + 1), book, limit, wanted.ids)
        compare(view.result, wanted)
    end
    phase = 'open_detail'
    assert(view.result.items[input.review_index].review_id == review)
    view._review_buttons[input.review_index].callback()
    local detail = assert(host._native_reviews_owner.detail)
    detail.buttons_table[1][1].callback()
    phase = 'replies_first'
    wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
    local replies = host._native_review_replies_owner.view
    local expected_first = ReplyModel.project(client, input.first, book, review, 20)
    compare(replies.result, expected_first)
    assert(#replies.result.items == 20 and replies.result.has_more)
    UI:forceRePaint(); painted = true
    replies._review_buttons[1].callback()
    local detail_reply = assert(host._native_review_replies_owner.viewer)
    assert(detail_reply.text:find(replies.result.items[1].content, 1, true)); detail_reply:onClose()
    phase = 'replies_more'
    replies._review_buttons[#replies._review_buttons].callback()
    local previous = replies
    wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view ~= previous end)
    replies = host._native_review_replies_owner.view
    local expected_second = ReplyModel.project(client, input.second, book, review, 40, expected_first.ids)
    compare(replies.result, expected_second)
    UI:forceRePaint(); replies:onClose(); detail:onClose(); view:onClose()
    assert(not host._native_review_replies_owner and not host._native_reviews_owner and not host.busy_message and counter[0] == 5)
    phase = 'complete'
end)
io.write('\nWEREAD_NATIVE_REPLIES_UI=' .. json.encode({result = ok and 'PASS' or 'UNVERIFIED', phase = phase,
    requests = tonumber(counter[0]), painted = painted, heartbeat = heartbeat}) .. '\n')
