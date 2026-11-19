-- Real account thought/reply data and HTTPS in memory only. No screenshots or files.
require('ffi').log = function() end
require('setupkoenv')
local cache_mode=os.getenv('WEREAD_THOUGHT_REPLY_CACHE_MODE')
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
    local scope = {vid = vid, epoch = 1}
    local native_store = {read = function() return grant, 1, nil, false end}
    package.preload['weread.lib.native_credentials'] = function() return {new = function() return native_store end} end
    local settings = {data_dir = cache_mode and home or '/unused', get = function(_, key, fallback)
        if cache_mode and key=='account' then return {user_vid=vid} end
        if key == 'thought_popup' then return {position = 'center', height_ratio = 0.7, width_ratio = 0.8} end
        if key == 'cache' then return {ignore_edge_thought_taps = false} end
        return fallback
    end, get_auth_scope = function() return scope end, auth_scope_matches = function(_, value) return value == scope end}
    local Client = require('weread.lib.client')
    local client = Client:new(settings)
    local original = client.request
    client.request = function(self, options)
        local url = 'https://i.weread.qq.com/review/single?reviewId=' .. require('weread.lib.protocol').urlencode(review)
            .. '&commentsCount=21&commentsDirection=0&likesCount=0&synckey=0'
        assert(cache_mode~='offline' and counter[0] == 0 and options.url == url and options.method == 'GET' and not options.body
            and options.sensitive and options.skip_cookie and not options.persist_response_cookies)
        counter[0] = counter[0] + 1
        return original(self, options)
    end
    local range_row
    for _, row in ipairs(input.source.reviews) do if row.range == input.range then assert(not range_row); range_row = row end end
    assert(range_row and range_row.pageReviews[input.item_index].reviewId == review)
    local items = require('weread.lib.annotations').buildThoughtPopupItems(range_row)
    local pid = tonumber(ffi.C.getpid())
    local store = {get = function(_, id, kind, chapter)
        assert(tonumber(ffi.C.getpid()) ~= pid and id == book and kind == 'source' and chapter == input.chapter_uid)
        socket.sleep(0.15); return input.source
    end}
    local document = {configurable = {font_size = 18}, getPageMargins = function()
        return {left = 20, right = 20, top = 10, bottom = 10}
    end}
    local record = {book_id = book, chapter_uid = input.chapter_uid, range = input.range, items = items}
    local library=cache_mode and require('weread.lib.library_db'):new(settings)
        or {accountKey = function() return 'volatile-account' end}
    local host = {settings = settings, client = client, library_db = library,
        _annotation_context = {book_id = book, store = store}, _reader_session_gen = 1, discovery_epoch = 1,
        ui = {document = document, doc_props = {title = '微信读书'}},
        _xpointer_overlay = {enabled = true, hitTest = function() return record end}}
    function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
    function host:closeBusy() self.busy_message = nil end
    function host:showInfo() error('thought_reply_failed', 0) end
    function host:isNetworkOnline() return cache_mode~='offline' end
    function host:runOnlineTask(_, fn) UI:scheduleIn(0.01, fn); return true end
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
    phase = 'thought_popup'
    assert(require('weread.ui.xpointer_overlay_controller')._onXPointerOverlayTap(host,
        {pos = {x = math.floor(Device.screen:getWidth()/2), y = 200}}))
    local popup = assert(UI:getTopmostVisibleWidget())
    assert(popup.items == items and popup.on_replies)
    UI:forceRePaint(); popup:_showThoughtActionMenu(items[input.item_index])
    local menu = assert(UI:getTopmostVisibleWidget()); menu.buttons[2][1].callback()
    phase = 'resolve_and_read'
    UI:scheduleIn(0.05, function() heartbeat = true end)
    wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
    local replies = host._native_review_replies_owner.view
    local expected = require('weread.lib.native_review_replies').project(client, input.expected, book, review, 20, nil, 1)
    if cache_mode=='offline' then expected.has_more=false;assert(replies.tab_text=='Saved replies') end
    compare(replies.result, expected)
    assert(#replies.result.items > 0 and replies.title_text == 'Thought replies')
    UI:forceRePaint(); painted = true
    if cache_mode=='offline' then
        replies._review_buttons[1].callback();local viewer=assert(host._native_review_replies_owner.viewer)
        assert(viewer.text:find(expected.items[1].content,1,true));viewer:onClose()
    end
    popup:onClose()
    assert(not host._thought_reply_owner and not host._native_review_replies_owner and not host.busy_message
        and counter[0] == (cache_mode=='offline' and 0 or 1))
    require('weread.ui.thought_popup').cleanup()
    phase = 'complete'
end)
io.write('\nWEREAD_THOUGHT_REPLIES_UI=' .. json.encode({result = ok and 'PASS' or 'UNVERIFIED', phase = phase,
    requests = tonumber(counter[0]), painted = painted, heartbeat = heartbeat}) .. '\n')
