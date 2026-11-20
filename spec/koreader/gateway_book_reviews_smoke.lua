-- Real KOReader widgets and memory workers; synthetic Skill and native data.
require('setupkoenv')
package.path = (os.getenv('WEREAD_SOURCE') or '/source') .. '/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):open(assert(os.getenv('KO_HOME')) .. '/settings.reader.lua')
G_reader_settings:saveSetting('language', 'zh_CN'); require('gettext').changeLang('zh_CN')
local Device = require('device'); require('document/canvascontext'):init(Device)
local UI, json, socket, ffi = require('ui/uimanager'), require('json'), require('socket'), require('ffi')
local pid = tonumber(ffi.C.getpid())
local scope = {vid = '123', epoch = 1}
local settings = {data_dir = '/unused', get = function(_, key, fallback) if key == 'api_key' then return 'synthetic-key' end return fallback end,
    get_auth_scope = function() return scope end, auth_scope_matches = function(_, value) return value == scope end}
local grant = {vid = '123', accessToken = 'synthetic-token'}
local store = {read = function() return grant, 1, nil, false end}
local Source = require('weread.lib.gateway_book_reviews_source')
local selected = assert(Source.capture(settings, store))
assert(selected.native and selected.api_key)
local mock_port = tonumber(os.getenv('WEREAD_GATEWAY_MOCK_PORT'))
local client
if mock_port then
    assert(mock_port >= 1 and mock_port <= 65535)
    settings.mock_endpoint = 'http://127.0.0.1:' .. mock_port
    client = require('weread.lib.client'):new(settings)
else
    client = {settings = settings, json_encode = function(_, value) return json.encode(value) end,
        json_decode = function(_, value) return json.decode(value) end}
end
local function synthetic_gateway(self, book, mode, cursor, sync, key)
    assert(tonumber(ffi.C.getpid()) ~= pid and book == '42' and key == 'synthetic-key')
    socket.sleep(0.2)
    if cursor then assert(cursor == 20 and sync == 123) end
    local rows = self:json_decode('[]')
    local start = cursor and 21 or 1
    for i = start, start + 19 do
        local id = (mode == 1 and 'recommended-' or 'latest-') .. i
        rows[#rows + 1] = {idx = i, review = {reviewId = id, review = {reviewId = id, bookId = book,
            author = {name = '合成读者'}, content = '合成书评 ' .. i, star = 100, createTime = 1700001000 - i}}}
    end
    return {reviews = rows, reviewsHasMore = cursor and 0 or 1, synckey = 123}
end
if not mock_port then client.get_gateway_book_reviews = synthetic_gateway end
local ReplySource = require('weread.lib.native_book_reviews_source')
ReplySource.fetch_replies = function(codec, book, review, limit, previous)
    assert(tonumber(ffi.C.getpid()) ~= pid and book == '42' and review == 'recommended-1')
    socket.sleep(0.2)
    local rows = codec:json_decode('[]')
    for i = 1, limit + 1 do
        rows[i] = {reviewId = review, commentId = 'reply-' .. i, author = {name = '合成读者'},
            content = '合成回复 ' .. i, createTime = 1700001000 - i}
    end
    return require('weread.lib.native_review_replies').project(codec,
        {reviewId = review, review = {reviewId = review, bookId = book, type = 4}, comments = rows},
        book, review, limit, previous)
end
local host = {settings = settings, client = client, library_db = {accountKey = function() return 'synthetic-account' end},
    _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}}}
function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
function host:closeBusy() self.busy_message = nil end
function host:showInfo() error('unexpected failure') end
function host:runOnlineTask(_, fn) UI:scheduleIn(0.01, fn); return true end
host.showBookReviewDetail = require('weread.ui.library').showBookReviewDetail
local Gateway = require('weread.ui.gateway_book_reviews')
local function wait(predicate)
    local deadline = socket.gettime() + 15
    while not predicate() do
        UI:setInputTimeout(0); UI:handleInput(); socket.sleep(0.01)
        assert(socket.gettime() < deadline, 'gateway reviews timed out')
    end
end
UI:setRunForeverMode(); UI:setInputTimeout(0)
assert(Gateway.open(host, {book_id = '42', title = '合成书籍'}, selected))
local heartbeat = false; UI:scheduleIn(0.05, function() heartbeat = true end)
wait(function() return heartbeat end); assert(host._gateway_reviews_owner.context, 'gateway blocked UI heartbeat')
wait(function() return host._gateway_reviews_owner.view end)
local view = host._gateway_reviews_owner.view
assert(view.mode == 'recommended' and #view.result.items == 20 and #view._tab_buttons == 2)
UI:forceRePaint()
view._review_buttons[1].callback()
local detail = assert(host._gateway_reviews_owner.detail)
detail.buttons_table[1][1].callback()
wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
local replies = host._native_review_replies_owner.view
assert(#replies.result.items == 20 and replies.title_text == 'Review replies')
UI:forceRePaint(); replies:onClose(); detail:onClose()
assert(not host._native_review_replies_owner and not host._gateway_reviews_owner.detail)
view._review_scroll:setScrolledOffset({x = 0, y = 500})
view._review_buttons[21].callback()
local previous = view; wait(function() return host._gateway_reviews_owner.view ~= previous end)
view = host._gateway_reviews_owner.view
assert(#view.result.items == 40 and not view.result.has_more and #view.result.seen_cursors == 2
    and view.result.seen_cursors[1] == 20 and view.result.seen_cursors[2] == 40
    and view._review_scroll:getScrolledOffset().y == 500, 'gateway cursor or scroll roundtrip failed')
UI:forceRePaint(); view._tab_buttons[2].callback()
previous = view; wait(function() return host._gateway_reviews_owner.view ~= previous end)
view = host._gateway_reviews_owner.view
assert(view.mode == 'latest' and #view.result.items == 20)
view._tab_buttons[1].callback()
view = host._gateway_reviews_owner.view
assert(view.mode == 'recommended' and #view.result.items == 40, 'tab cache failed')
UI:forceRePaint(); view:onClose(); assert(not host._gateway_reviews_owner and not host.busy_message)
print('GATEWAY_BOOK_REVIEWS_SMOKE_PASS')
