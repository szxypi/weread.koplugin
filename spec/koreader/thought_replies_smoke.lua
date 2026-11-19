-- Real thought popups, cache resolution and reply widgets; synthetic data only.
require('setupkoenv')
package.path = (os.getenv('WEREAD_SOURCE') or '/source') .. '/?.lua;' .. package.path
G_defaults = require('luadefaults'):open()
G_reader_settings = require('luasettings'):open(assert(os.getenv('KO_HOME')) .. '/settings.reader.lua')
G_reader_settings:saveSetting('language', 'zh_CN'); require('gettext').changeLang('zh_CN')
local Device = require('device'); require('document/canvascontext'):init(Device)
local UI, json, socket, ffi = require('ui/uimanager'), require('json'), require('socket'), require('ffi')
local pid = tonumber(ffi.C.getpid())
local position = os.getenv('WEREAD_THOUGHT_POPUP_POSITION') or 'center'
local row = {range = '10-20', pageReviews = {
    {reviewId = 'thought-1', likesCount = 1, review = {reviewId = 'thought-1', bookId = '42', chapterUid = 7,
        type = 1, author = {name = '合成读者甲'}, content = '合成想法甲', abstract = '合成原文'}},
    {reviewId = 'thought-2', likesCount = 2, review = {reviewId = 'thought-2', bookId = '42', chapterUid = 7,
        type = 1, author = {name = '合成读者乙'}, content = '合成想法乙'}},
}}
local items = require('weread.lib.annotations').buildThoughtPopupItems(row)
local source = {book_id = '42', chapter_uid = '7', reviews = {row}}
local selected = {native = {scope = {vid = '123'}, revision = 1}}
local Source = require('weread.lib.native_book_reviews_source')
Source.capture = function() return selected end
Source.matches = function(_, value) return value == selected end
Source.fetch_replies = function(client, book, review, limit, previous, _, _, review_type)
    assert(tonumber(ffi.C.getpid()) ~= pid and book == '42' and review == 'thought-2' and review_type == 1)
    socket.sleep(0.15)
    local rows = client:json_decode('[]')
    for i = 1, limit + 1 do
        rows[i] = {reviewId = review, commentId = 'reply-' .. i, author = {name = '合成读者'},
            content = '合成回复 ' .. i, createTime = 1700001000 - i}
    end
    return require('weread.lib.native_review_replies').project(client,
        {reviewId = review, review = {reviewId = review, bookId = book, type = 1}, comments = rows},
        book, review, limit, previous, 1)
end
local settings = {get = function(_, key, fallback)
    if key == 'thought_popup' then return {position = position, height_ratio = 0.7, width_ratio = 0.8} end
    if key == 'cache' then return {ignore_edge_thought_taps = false} end
    return fallback
end}
local lfs = require('libs/libkoreader-lfs')
local cache_dir = assert(os.getenv('KO_HOME')) .. '/thought-replies-' .. tostring(pid)
assert(lfs.mkdir(cache_dir))
settings.data_dir = cache_dir
local persisted = require('weread.lib.annotation_store'):new(settings)
persisted:put('42', 'source', '7', source, '7')
persisted:put('42', 'thought', '7:10-20', items, '7')
local store = {get = function(_, book, kind, key)
    assert(book == '42')
    if kind == 'source' then
        assert(tonumber(ffi.C.getpid()) ~= pid and key == '7')
        socket.sleep(0.15)
    end
    return persisted:get(book, kind, key)
end}
local document = {configurable = {font_size = 18}, getPageMargins = function()
    return {left = 20, right = 20, top = 10, bottom = 10}
end}
local client = {json_encode = function(_, value) return json.encode(value) end,
    json_decode = function(_, value) return json.decode(value) end}
local record = {book_id = '42', chapter_uid = '7', range = '10-20'}
local host = {settings = settings, client = client, library_db = {accountKey = function() return 'synthetic-account' end},
    _annotation_context = {book_id = '42', store = store}, _reader_session_gen = 1, discovery_epoch = 1,
    ui = {document = document, doc_props = {title = '合成书籍'}},
    _xpointer_overlay = {enabled = true, hitTest = function() return record end}}
function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
function host:closeBusy() self.busy_message = nil end
function host:showInfo() error('unexpected failure') end
function host:runOnlineTask(_, fn) UI:scheduleIn(0.01, fn); return true end
local Overlay = require('weread.ui.xpointer_overlay_controller')
local Popup = require('weread.ui.thought_popup')
local function wait(predicate)
    local deadline = socket.gettime() + 15
    while not predicate() do
        UI:setInputTimeout(0); UI:handleInput(); socket.sleep(0.01)
        assert(socket.gettime() < deadline, 'thought replies timed out')
    end
end
UI:setRunForeverMode(); UI:setInputTimeout(0)
assert(Overlay._onXPointerOverlayTap(host, {pos = {x = math.floor(Device.screen:getWidth()/2), y = 200}}))
local popup = assert(UI:getTopmostVisibleWidget())
local shown = popup.items
assert(#shown == 2 and shown[2].content == items[2].content and not shown[2].review_id and popup.on_replies)
if position == 'center' then assert(popup:_title():find('长按', 1, true)) else assert(popup._reply_hint) end
UI:forceRePaint()
local evidence = os.getenv('WEREAD_THOUGHT_SCREENSHOT')
if evidence then Device.screen:shot(evidence) end
popup:_showThoughtActionMenu(shown[2])
local menu = assert(UI:getTopmostVisibleWidget())
assert(menu.buttons[2][1].text == '查看回复')
menu.buttons[2][1].callback()
local heartbeat = false; UI:scheduleIn(0.05, function() heartbeat = true end)
wait(function() return heartbeat end); assert(host._thought_reply_owner, 'resolver blocked UI heartbeat')
wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
local replies = host._native_review_replies_owner.view
assert(replies.title_text == 'Thought replies' and #replies.result.items == 20)
UI:forceRePaint(); popup:onClose()
assert(not host._thought_reply_owner and not host._native_review_replies_owner and not host.busy_message)
local reused = Popup.show{pages = items, position = position}
assert(reused == popup and not reused.on_replies, 'pooled popup retained stale reply action')
if position == 'bottom' then assert(not reused._reply_hint) end
reused:onClose(); Popup.cleanup()
assert(persisted:clearBook('42'))
assert(lfs.rmdir(cache_dir .. '/external-annotations'))
assert(lfs.rmdir(cache_dir))
print('THOUGHT_REPLIES_SMOKE_PASS')
