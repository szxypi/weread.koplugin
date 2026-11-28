-- Real native replies through the Skill UI; Skill pages are synthetic wrappers
-- around independently read public reviews. Private pipes, no screenshots/files.
require('ffi').log = function() end
require('setupkoenv')
package.path = '/source/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):wrap({language = 'zh_CN'})
require('gettext').changeLang('zh_CN')
local json, ffi = require('json'), require('ffi')
local input = json.decode(assert(io.read('*a')))
pcall(ffi.cdef, 'void *mmap(void *, unsigned long, int, int, int, long);')
local memory = ffi.C.mmap(nil, 4096, 3, 0x21, -1, 0)
assert(memory ~= ffi.cast('void *', -1))
local counts = ffi.cast('int *', memory); counts[0], counts[1] = 0, 0
local phase, painted, heartbeat = 'setup', false, false
local ok = pcall(function()
    local Device = require('device'); require('document/canvascontext'):init(Device)
    Device.screen.shot = function() error('screenshots_disabled', 0) end
    local UI, socket = require('ui/uimanager'), require('socket')
    local grant, book, review = assert(input.credentials), assert(input.book_id), assert(input.review_id)
    assert(type(book) == 'string' and book:match('^[1-9]%d*$') and #book <= 20)
    local scope = {vid = grant.vid, epoch = 1}
    local store = {read = function() return grant, 1, nil, false end}
    local settings = {data_dir = '/unused', get = function(_, key, fallback)
        if key == 'api_key' then return 'synthetic-skill' end
        return fallback
    end, get_auth_scope = function() return scope end, auth_scope_matches = function(_, value) return value == scope end}
    local Client = require('weread.lib.client')
    local client = Client:new(settings)
    function client:get_gateway_book_reviews(id, mode, cursor, sync, key)
        assert(id == book and mode == 1 and key == 'synthetic-skill')
        local start = cursor and cursor + 1 or 1
        assert(start == 1 or start == 21 or start == 41)
        assert(not cursor or sync == 123)
        counts[1] = counts[1] + 1
        local rows = self:json_decode('[]')
        for index = start, math.min(start + 19, #input.listing.reviews) do
            local row = input.listing.reviews[index]
            rows[#rows + 1] = {idx = index, review = {reviewId = row.reviewId, review = row.review}}
        end
        return {reviews = rows, reviewsHasMore = start + 19 < #input.listing.reviews and 1 or 0, synckey = 123}
    end
    local original = client.request
    client.request = function(self, options)
        local count = counts[0] == 0 and 21 or 41
        local url = 'https://i.weread.qq.com/review/single?reviewId=' .. require('weread.lib.protocol').urlencode(review)
            .. '&commentsCount=' .. count .. '&commentsDirection=0&likesCount=0&synckey=0'
        assert(counts[0] < 2 and options.url == url and options.method == 'GET' and not options.body
            and options.sensitive and options.skip_cookie and not options.persist_response_cookies)
        counts[0] = counts[0] + 1
        return original(self, options)
    end
    local Source = require('weread.lib.gateway_book_reviews_source')
    local ReplyModel = require('weread.lib.native_review_replies')
    local Gateway = require('weread.ui.gateway_book_reviews')
    local selected = assert(Source.capture(settings, store))
    assert(selected.api_key and selected.native)
    local host = {settings = settings, client = client, library_db = {accountKey = function() return 'volatile-account' end},
        _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}}}
    function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
    function host:closeBusy() self.busy_message = nil end
    function host:showInfo() error('gateway_ui_failed', 0) end
    function host:runOnlineTask(_, fn) UI:scheduleIn(0.01, fn); return true end
    host.showBookReviewDetail = require('weread.ui.library').showBookReviewDetail
    local function wait(predicate)
        local deadline = socket.gettime() + 30
        while not predicate() do
            UI:setInputTimeout(0); UI:handleInput(); socket.sleep(0.01)
            assert(socket.gettime() < deadline)
        end
    end
    local function compare(actual, expected)
        assert(#actual.items == #expected.items and actual.has_more == expected.has_more)
        for index, item in ipairs(actual.items) do
            local other = expected.items[index]
            for _, field in ipairs({'review_id', 'author', 'content', 'rating', 'create_time', 'is_finish'}) do
                assert(item[field] == other[field])
            end
        end
    end
    UI:setRunForeverMode(); UI:setInputTimeout(0)
    phase = 'gateway_first'
    assert(Gateway.open(host, {book_id = book, title = '微信读书'}, selected))
    UI:scheduleIn(0.05, function() heartbeat = true end)
    wait(function() return host._gateway_reviews_owner and host._gateway_reviews_owner.view end)
    local view = host._gateway_reviews_owner.view
    assert(#view.result.items == 20 and view.result.has_more)
    for _, limit in ipairs({40, 60}) do
        phase = 'gateway_more_' .. limit
        view._review_buttons[#view._review_buttons].callback()
        local previous = view
        wait(function() return host._gateway_reviews_owner and host._gateway_reviews_owner.view ~= previous end)
        view = host._gateway_reviews_owner.view
        assert(#view.result.items == limit)
    end
    phase = 'open_detail'
    assert(view.result.items[input.review_index].review_id == review)
    view._review_buttons[input.review_index].callback()
    local detail = assert(host._gateway_reviews_owner.detail)
    detail.buttons_table[1][1].callback()
    phase = 'replies_first'
    wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
    local replies = host._native_review_replies_owner.view
    local first = ReplyModel.project(client, input.first, book, review, 20)
    compare(replies.result, first)
    assert(#replies.result.items == 20 and replies.result.has_more)
    UI:forceRePaint(); painted = true
    phase = 'replies_more'
    replies._review_buttons[#replies._review_buttons].callback()
    local previous = replies
    wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view ~= previous end)
    replies = host._native_review_replies_owner.view
    compare(replies.result, ReplyModel.project(client, input.second, book, review, 40, first.ids))
    UI:forceRePaint(); replies:onClose(); detail:onClose(); view:onClose()
    assert(not host._native_review_replies_owner and not host._gateway_reviews_owner and not host.busy_message
        and counts[0] == 2 and counts[1] == 3)
    phase = 'complete'
end)
io.write('\nWEREAD_NATIVE_REPLIES_UI=' .. json.encode({result = ok and 'PASS' or 'UNVERIFIED', phase = phase,
    requests = tonumber(counts[0]), synthetic_gateway_calls = tonumber(counts[1]), painted = painted, heartbeat = heartbeat}) .. '\n')
