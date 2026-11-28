-- Private owner input; native UI, memory worker and two read-only requests.
-- No screenshots, real review files, persistent credentials or diagnostic text.
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
local counter = ffi.cast('int *', memory)
counter[0] = 0
local phase, painted, heartbeat = 'setup', false, false
local ok = pcall(function()
    assert(memory ~= ffi.cast('void *', -1))
    local Device = require('device')
    require('document/canvascontext'):init(Device)
    Device.screen.shot = function() error('screenshots_disabled', 0) end
    local UI, socket = require('ui/uimanager'), require('socket')
    local grant, book = assert(input.credentials), assert(input.book_id)
    assert(type(book) == 'string' and book:match('^[1-9]%d*$') and #book <= 20)
    local scope = {vid = grant.vid, epoch = 1}
    local store = {read = function() return grant, 1, nil, false end}
    local settings = {data_dir = '/unused', get = function(_, _, fallback) return fallback end,
        get_auth_scope = function() return scope end, auth_scope_matches = function(_, value) return value == scope end}
    local Client = require('weread.lib.client')
    local client = Client:new(settings)
    local original = client.request
    client.request = function(self, options)
        local count = counter[0] == 0 and 21 or 41
        local url = 'https://i.weread.qq.com/review/list?bookId=' .. book
            .. '&listType=3&listMode=1&synckey=0&count=' .. count .. '&maxIdx=0&tips=1'
        assert(counter[0] < 2 and options.url == url and options.method == 'GET' and not options.body
            and options.sensitive and options.skip_cookie and not options.persist_response_cookies)
        counter[0] = counter[0] + 1
        return original(self, options)
    end
    local Source = require('weread.lib.native_book_reviews_source')
    local Model = require('weread.lib.native_book_reviews')
    local Reviews = require('weread.ui.native_book_reviews')
    local selected = assert(Source.capture(settings, store))
    local host = {settings = settings, client = client, library_db = {accountKey = function() return 'volatile-account' end},
        _book_detail_view = {}, discovery_epoch = 1, _reader_session_gen = 1, ui = {document = {}}}
    function host:showBusy(_, cancel) self.busy_message = {}; self.cancel_busy = cancel end
    function host:closeBusy() self.busy_message = nil end
    function host:showInfo() error('review_ui_failed', 0) end
    function host:runOnlineTask(_, fn) UI:scheduleIn(0.01, fn); return true end
    function host:showBookReviewDetail(_, item) self.chosen = item.review_id end
    local function wait(predicate)
        local deadline = socket.gettime() + 30
        while not predicate() do
            UI:setInputTimeout(0); UI:handleInput(); socket.sleep(0.01)
            assert(socket.gettime() < deadline)
        end
    end
    local function compare(actual, expected)
        assert(#actual.items == #expected.items and actual.has_more == expected.has_more)
        for index, review in ipairs(actual.items) do
            local other = expected.items[index]
            for _, field in ipairs({'review_id', 'author', 'content', 'rating', 'create_time', 'is_finish'}) do
                assert(review[field] == other[field])
            end
        end
    end
    UI:setRunForeverMode(); UI:setInputTimeout(0)
    phase = 'first_load'
    assert(Reviews.open(host, {book_id = book, title = '微信读书'}, selected))
    UI:scheduleIn(0.05, function() heartbeat = true end)
    wait(function() return host._native_reviews_owner and host._native_reviews_owner.view ~= nil end)
    local view = host._native_reviews_owner.view
    phase = 'first_compare'
    local expected = Model.project(client, input.first, book, 20)
    compare(view.result, expected)
    assert(view.latest_only and #view._tab_buttons == 2 and view.result.has_more)
    UI:forceRePaint(); painted = true
    phase = 'second_load'
    view._review_buttons[#view._review_buttons].callback()
    wait(function() return host._native_reviews_owner and host._native_reviews_owner.view ~= view end)
    view = host._native_reviews_owner.view
    phase = 'second_compare'
    compare(view.result, Model.project(client, input.second, book, 40, expected.ids))
    UI:forceRePaint()
    view:onClose()
    assert(not host._native_reviews_owner and not host.busy_message and counter[0] == 2)
    phase = 'complete'
end)
io.write('\nWEREAD_NATIVE_REVIEWS_UI=' .. json.encode({result = ok and 'PASS' or 'UNVERIFIED', phase = phase,
    requests = tonumber(counter[0]), painted = painted, heartbeat = heartbeat}) .. '\n')
