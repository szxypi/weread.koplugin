-- Actual KOReader widgets and forked worker, synthetic data only.
require('setupkoenv')
package.path = '/source/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):open(assert(os.getenv('KO_HOME')) .. '/settings.reader.lua')
G_reader_settings:saveSetting('language', 'zh_CN')
require('gettext').changeLang('zh_CN')
local Device = require('device')
require('document/canvascontext'):init(Device)
local UI = require('ui/uimanager')
local json = require('json')
local socket = require('socket')
local ffi = require('ffi')
local pid = tonumber(ffi.C.getpid())
local Source = require('weread.lib.native_book_reviews_source')
local selected = {native = {scope = {vid = '123'}, revision = 1}}
Source.matches = function(_, value) return value == selected end
Source.fetch = function(client, book, limit, previous)
    assert(tonumber(ffi.C.getpid()) ~= pid and book == '42')
    socket.sleep(0.2)
    local raw = {reviews = client:json_decode('[]'), hasMore = 0}
    for i = 1, limit + 1 do
        local id = 'synthetic-' .. i
        raw.reviews[i] = {reviewId = id, review = {reviewId = id, bookId = '42', type = 4,
            createTime = 1700001000 - i, author = {name = '合成读者'}, content = '合成书评 ' .. i, star = 100}}
    end
    return require('weread.lib.native_book_reviews').project(client, raw, book, limit, previous)
end
local client = {json_encode = function(_, v) return json.encode(v) end,
    json_decode = function(_, v) return json.decode(v) end}
local owner_account = 'synthetic'
local host = {settings = {}, client = client, library_db = {accountKey = function() return owner_account end},
    _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}}}
function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
function host:closeBusy() self.busy_message = nil end
function host:showInfo() error('unexpected failure') end
function host:runOnlineTask(_, fn) UI:scheduleIn(0.01, fn); return true end
function host:showBookReviewDetail(_, item) self.chosen = item.review_id end
local Reviews = require('weread.ui.native_book_reviews')
local function wait(predicate)
    local deadline = socket.gettime() + 15
    while not predicate() do
        UI:setInputTimeout(0); UI:handleInput(); socket.sleep(0.01)
        assert(socket.gettime() < deadline, 'native reviews timed out')
    end
end
UI:setRunForeverMode(); UI:setInputTimeout(0)
assert(Reviews.open(host, {book_id = '42', title = '合成书籍'}, selected))
local heartbeat = false
UI:scheduleIn(0.05, function() heartbeat = true end)
wait(function() return heartbeat end)
assert(host._native_reviews_owner.context, 'worker blocked UI heartbeat')
wait(function() return host._native_reviews_owner.view ~= nil end)
local view = host._native_reviews_owner.view
assert(view.latest_only and #view._tab_buttons == 1 and #view._review_buttons == 21)
UI:forceRePaint()
view._review_buttons[1].callback(); assert(host.chosen == 'synthetic-1')
view._review_scroll:setScrolledOffset({x = 0, y = 500})
view._review_buttons[21].callback()
wait(function() return host._native_reviews_owner.view ~= view end)
view = host._native_reviews_owner.view
assert(#view.result.items == 40 and #view._review_buttons == 41)
assert(view._review_scroll:getScrolledOffset().y == 500, 'more reviews lost the prior scroll position')
UI:forceRePaint()
view:onClose()
assert(not host._native_reviews_owner and not host.busy_message)
print('NATIVE_BOOK_REVIEWS_SMOKE_PASS')
