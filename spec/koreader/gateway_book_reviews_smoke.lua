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
local key_only=os.getenv('WEREAD_GATEWAY_KEY_ONLY')=='1'
local offline=os.getenv('WEREAD_GATEWAY_REOPEN')=='1'
local vid='123'
local settings = {data_dir = assert(os.getenv('KO_HOME')), get = function(_, key, fallback)
    if key == 'api_key' then return 'synthetic-key' end
    if key == 'account' then return key_only and {} or {user_vid=vid} end
    return fallback end,
    get_auth_scope = function() return scope end, auth_scope_matches = function(_, value) return value == scope end}
if key_only then
    settings.get_auth_scope=function() return nil end;settings.auth_scope_matches=function() return false end
    settings.settings_file=settings.data_dir..'/gateway-fixture.lua'
    local file=assert(io.open(settings.settings_file,'w'));assert(file:write("return { api_key='synthetic-key' }"));assert(file:close())
end
local grant = {vid = '123', accessToken = 'synthetic-token'}
local store = {read = function() return grant, 1, nil, false end}
local Source = require('weread.lib.gateway_book_reviews_source')
local selected
if not offline then
    selected=assert(Source.capture(settings, key_only and nil or store))
    assert(selected.api_key and (key_only and selected.key_only or not key_only and selected.native))
end
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
local image_url='https://weread-picture-1258476243.file.myqcloud.com/gateway-fixture.png'
if mock_port then
    local request=client.request
    function client:request(options)
        if options.url==image_url then
            assert(options.method=='GET' and options.skip_cookie and options.sensitive and not options.persist_response_cookies
                and not options.headers.Cookie and not options.headers.Authorization)
            assert(options.sink(require('weread.lib.native_missing_image')));options.sink(nil);return nil,200
        end
        return request(self,options)
    end
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
local host = {settings = settings, client = client, library_db = require('weread.lib.library_db'):new(settings),
    _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}}}
function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
function host:closeBusy() self.busy_message = nil end
function host:showInfo() error('unexpected failure') end
function host:isNetworkConnected() return not offline end
host.isNetworkOnline=host.isNetworkConnected
function host:runOnlineTask(_, fn)
    assert(not offline,'offline reviews scheduled network work')
    UI:scheduleIn(0.01, fn); return true
end
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
if offline then
    client.request=function() error('offline review attempted HTTP') end
    local show=require('weread.ui.library').showBookReviews
    local book={book_id='42',title='合成书籍'}
    local message
    host.showInfo=function(_self,value) message=value end
    if not key_only then
        assert(show(host,book))
        wait(function() return host._gateway_reviews_owner and host._gateway_reviews_owner.view end)
        local view=host._gateway_reviews_owner.view
        assert(view.mode=='recommended' and #view.result.items==40 and not view.result.has_more
            and not view.result.seen_cursors and #view._review_buttons==40
            and view.incomplete_text:find('保存于',1,true),'could not restore the saved recommendation list')
        assert(view.result.items[1].review_id=='recommended-1' and view.result.items[40].review_id=='recommended-40')
        view._review_buttons[1].callback()
        local detail=assert(host._gateway_reviews_owner.detail)
        assert(detail.text:find('合成书评 1',1,true),'cached review body was not visible')
        detail:onClose()
        view._tab_buttons[2].callback()
        wait(function() return host._gateway_reviews_owner.view~=view end)
        local latest=host._gateway_reviews_owner.view
        assert(latest.mode=='latest' and #latest.result.items==20 and not latest.result.has_more
            and latest.result.items[1].review_id=='latest-1','latest tab reused another saved list')
        latest:onClose();vid='124'
    end
    show(host,book)
    wait(function() return message~=nil end)
    assert(not host._gateway_reviews_owner and not host._native_reviews_owner,'isolated account saw saved reviews')
    print('GATEWAY_BOOK_REVIEWS_OFFLINE_PASS');os.exit(0)
end
assert(Gateway.open(host, {book_id = '42', title = '合成书籍'}, selected))
local heartbeat = false; UI:scheduleIn(0.05, function() heartbeat = true end)
wait(function() return heartbeat end); assert(host._gateway_reviews_owner.context, 'gateway blocked UI heartbeat')
wait(function() return host._gateway_reviews_owner.view end)
local view = host._gateway_reviews_owner.view
assert(view.mode == 'recommended' and #view.result.items == 20 and #view._tab_buttons == 2)
UI:forceRePaint()
view._review_buttons[1].callback()
local detail = assert(host._gateway_reviews_owner.detail)
if mock_port then
    local image_button=detail.buttons_table[key_only and 1 or 2][1]
    assert(image_button.id=='review_image_1');image_button.callback()
    wait(function() local own=host._gateway_reviews_owner.review_image_owner;return own and own.widget end)
    local image=host._gateway_reviews_owner.review_image_owner.widget
    assert(image.title_text=='书评图片' and image.image);UI:forceRePaint();UI:close(image)
    assert(not host._gateway_reviews_owner.review_image_owner and host._gateway_reviews_owner.detail==detail)
end
if not key_only then
    detail.buttons_table[1][1].callback()
    wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
    local replies = host._native_review_replies_owner.view
    assert(#replies.result.items == 20 and replies.title_text == 'Review replies')
    UI:forceRePaint();replies:onClose()
end
detail:onClose()
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
