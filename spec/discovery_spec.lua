package.path = "./?.lua;./?/init.lua;" .. package.path
local Data = require("weread.lib.discovery_data")
local Header = require("weread.lib.home_header_layout")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local result = Data.page("search", { hasMore = 1, results = {
    { books = { { searchIdx = 4, bookInfo = { bookId = "a", title = "A" } },
        { searchIdx = 8, bookInfo = { bookId = "a" } }, false, { bookId = "b", idx = 9 } } },
} }, 0)
expect(#result.books == 2 and result.next_cursor == 9 and result.has_more, "search deduplication or cursor lost")
expect(not Data.page("recommend", { books = { { bookId = "a" } }, hasMore = true }, 9).has_more,
    "non-advancing cursor must not cause an endless next-batch loop")
expect(not pcall(Data.page, "recommend", {}, 0), "malformed response treated as empty success")
expect(#Data.page("search", { results = {} }, 0).books == 0, "empty search rejected")
local similar = Data.page("similar", { booksimilar = { sessionId = "session-a", hasMore = true, books = {
    { idx = 21, book = { bookInfo = { bookId = "similar-a", title = "Similar A" } } },
    { idx = 22, book = { bookInfo = { bookId = "similar-a" } } },
} } }, 0)
expect(#similar.books == 1 and similar.books[1].title == "Similar A"
    and similar.next_cursor == 22 and similar.session_id == "session-a" and similar.has_more,
    "nested similar response or cursor/session lost")
expect(not pcall(Data.page, "similar", { books = {} }, 0), "similar container silently ignored")
expect(#Data.page("similar", { booksimilar = { books = {} } }, 0).books == 0, "empty similar rejected")
local books = { { bookId = "a", readUpdateTime = 10 }, { bookId = "b", readUpdateTime = 20 }, { bookId = "c" } }
expect(Data.recent(books)[1].bookId == "b" and books[1].bookId == "a", "recent sort mutated shelf order")
expect(#Data.recent(books) == 2, "unread books included in recent reading")
local saved_reading = { c = { recent_read_at = 30, recent_read_account = "a" } }
expect(Data.recent(books, saved_reading, "a")[1].bookId == "c", "offline reading missing from home")
expect(#Data.recent(books, saved_reading, "b") == 2, "local reading leaked across accounts")
expect(books[1]._recent_time == nil, "recent metadata mutated cloud shelf")
local off_shelf={
    ['900001']={book_id='900001',title='Local book',author='Local author',recent_read_at=50,recent_read_account='a',_library_account_key='a'},
    ['CB_LocalBook']={book_id='CB_LocalBook',title='Imported local book',recent_read_at=40,recent_read_account='a'},
    ['900002']={book_id='900002',title='Other account',recent_read_at=60,recent_read_account='b',_library_account_key='b'},
    ['900003']={book_id='900004',title='Mismatched record',recent_read_at=70,recent_read_account='a'},
    ['MP_WXS_123']={book_id='MP_WXS_123',title='Article container',recent_read_at=80,recent_read_account='a'},
    ['900005']={book_id='900005',title='Foreign metadata',recent_read_at=90,recent_read_account='a',_library_account_key='b'},
}
local recent_local=Data.recent(books,off_shelf,'a')
expect(#recent_local==4 and recent_local[1].bookId=='900001' and recent_local[2].bookId=='CB_LocalBook',
    'recent reading omitted an off-shelf local book or accepted a foreign or mismatched record')
expect(recent_local[1].title=='Local book' and recent_local[1].author=='Local author'
    and not recent_local[1].pending_upload_position and not off_shelf['900001']._recent_time,
    'local recent reading exposed internal state or modified its source')
expect(#Data.recent(books,off_shelf,nil)==2,'signed-out home displayed another account\'s local records')
expect(#Data.recent(books,off_shelf,'b')==3,'home showed other-account local reading')
local edge_shelf={{bookId='900001',title='Cloud title',readUpdateTime=1},
    {bookId='900001',title='Duplicate',readUpdateTime=2}}
local edge_saved={
    ['900001']={book_id='900001',title='Private local title',recent_read_at=100,recent_read_account='a'},
    ['900002']={book_id='900002',bookId='900003',recent_read_at=99,recent_read_account='a'},
    ['900004']={book_id='900004',title='invalid\nname',recent_read_at=98,recent_read_account='a'},
    ['900005']={book_id='900005',recent_read_at=math.huge,recent_read_account='a'},
    ['900006']={book_id='900006',recent_read_at=0/0,recent_read_account='a'},
    ['900007']={book_id='900007',recent_read_at=-1,recent_read_account='a'},
}
local edge=Data.recent(edge_shelf,edge_saved,'a')
expect(#edge==2 and edge[1].title=='Cloud title' and edge[2].title=='900004',
    'recent books failed identity deduplication or safe local display fallback')
expect(#Data.recent({},off_shelf,'')==0 and #Data.recent({},edge_saved,nil)==0,
    'unscoped recent readings appeared on home')
expect(#Data.recent({},off_shelf,'a',1)==2,'invalid home limit changed the configured default')
for _, width in ipairs({ 120, 320, 600, 1072, 1440 }) do
    local layout = Header.arrange(width, {
        { key = "back", width = 72 }, { key = "title", width = 200 },
        { key = "search", width = 72 }, { key = "refresh", width = 72 },
    }, 0)
    for i, item in ipairs(layout) do
        expect(item.x >= 0 and item.x + item.width <= width, "header exceeds viewport")
        expect(i == 1 or item.x >= layout[i - 1].x + layout[i - 1].width, "header overlaps")
    end
end

package.preload["ui/uimanager"] = function() return { close = function() end } end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s) return s end, display_error = tostring }
end
local Discovery = require("weread.ui.discovery")
local queued, requests, rendered, error_text, account = nil, {}, 0, nil, "account-a"
local fail = false
local plugin = setmetatable({
    library_db = { accountKey = function() return account end },
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _title, fn) queued = fn return true end,
    client = { gateway = function(_self, api, params)
        requests[#requests + 1] = { api = api, params = params }
        if fail then error("offline") end
        return { books = { { bookId = "a", searchIdx = params.maxIdx + 20 } }, hasMore = true }
    end },
    showInfo = function(_self, message) error_text = message end,
    showBookstore = function() rendered = rendered + 1 end,
}, { __index = Discovery })
require("spec.helpers.discovery_fixture").attach(plugin)
plugin:loadDiscoveryBatch("recommend", nil, 0)
expect(#requests == 0 and plugin.discovery_loading, "request bypassed online task")
queued()
expect(rendered == 1 and requests[1].api == "/book/recommend", "recommendations not displayed")
expect(plugin.discovery_state.next_cursor == 20, "next cursor lost")
plugin:loadDiscoveryBatch("recommend", nil, 20)
queued()
expect(plugin.discovery_state.history[1] == 0, "previous batch cursor not retained")
plugin:loadDiscoveryBatch("recommend", nil, 0, true)
queued()
expect(#plugin.discovery_state.history == 0, "back navigation did not consume cursor")
local saved = plugin.discovery_state
fail = true
plugin:loadDiscoveryBatch("recommend", nil, 20)
queued()
expect(plugin.discovery_state == saved and error_text, "failure discarded visible books")
fail = false
plugin:loadDiscoveryBatch("recommend", nil, 20)
plugin.discovery_epoch = 1
queued()
expect(plugin.discovery_state == saved and rendered == 3, "late result reopened a closed page")
plugin:loadDiscoveryBatch("recommend", nil, 20)
account = "account-b"
queued()
expect(plugin.discovery_state == saved, "result crossed account boundary")
plugin.runOnlineTask = function() return false end
plugin:loadDiscoveryBatch("recommend", nil, 20)
expect(not plugin.discovery_loading, "cancelled network task left loading locked")

-- Cover completion rebuilds widgets; it must not invalidate the current request.
plugin.runOnlineTask = function(_self, _title, fn) queued = fn return true end
plugin:loadDiscoveryBatch("recommend", nil, 0)
plugin.shelf_view = {}
queued()
expect(plugin.discovery_state.account == "account-b" and rendered == 4, "cover redraw discarded current result")

local shown, opened, fetched
package.preload["weread.ui.library_view"] = function()
    return {
        getLayout = function(_cover, _count, _mode, reserved)
            expect(reserved == 108, "home did not reserve actions and navigation")
            return { page_size = 6, columns = 3, rows = 2 }
        end,
        show = function(data, callbacks)
            shown = { data = data, callbacks = callbacks }
            return { page = data.page, page_size = data.page_size }
        end,
    }
end
plugin.settings = { get = function() return { a = { book_id = "a", cached_chapters = {} } } end }
plugin.getShelfCoverCache = function() return { pathFor = function() return nil end } end
plugin.cancelShelfCovers = function(self) self.shelf_cover_generation=(self.shelf_cover_generation or 0)+1 end
plugin.isBookDownloaded = function() return true end
plugin.fetchVisibleShelfCovers = function(_self, _view, _books, options) fetched = options end
plugin.startBookReading = function(_self, book) opened = book end
plugin.closeWeReadUI = function(self) self.shelf_view = nil self.discovery_epoch = self.discovery_epoch + 1 end
plugin:showDiscoveryPage("home", { { bookId = "a" } }, { title = "Home" })
expect(shown.data.portal and #shown.data.navigation == 4, "home navigation missing")
shown.callbacks.on_select({ bookId = "a", _cached = true })
expect(opened and opened.cached_chapters, "offline continue did not use saved chapter cache")
fetched.on_redraw(1)
expect(shown.data.title == "Home", "cover completion lost home context")
shown.callbacks.on_close()
expect(plugin.shelf_view == nil, "close left stale discovery view")
local persisted, flushed
plugin.settings = {
    patch_reading_state = function(_self,id,value) expect(id=='a','recent event addressed the wrong book');persisted=value;return true end,
    set = function() error('recent event rewrote all books') end,
    flush = function() flushed = true end,
}
plugin:recordRecentReading("a")
expect(not flushed and persisted.home_recent_at > 0 and persisted.home_recent_account == "account-b"
    and persisted.recent_read_account==nil, "recent event overwrote legacy position ownership")
local legacy={book_id='900001',recent_read_at=30,recent_read_account='a',home_recent_at=40,home_recent_account='b'}
expect(Data.recent({}, {['900001']=legacy},'b')[1].bookId=='900001'
    and #Data.recent({}, {['900001']=legacy},'a')==0,'new home event did not supersede its legacy event')
legacy.home_recent_account=''
expect(#Data.recent({}, {['900001']=legacy},'a')==0,'signed-out event revived a legacy account')

-- A successful network read must remain visible when saving the shelf fails.
local cached={{bookId='old',title='Old',readUpdateTime=10}}
local fresh={{bookId='new',title='Fresh',readUpdateTime=20}}
local refresh_saved=false
local home_render,home_notice
local home=setmetatable({
    library_db={accountKey=function() return 'home-account' end,getShelf=function() return cached end,
        getShelfArchives=function() return {} end},
    settings={get=function(_self,key) if key=='books' then return {} end end},
    homePreferences=function() return {recent_limit=12} end,
    homeShortcuts=function() return {} end,
    applyShelfSnapshot=function(self,rows) self.shelf_regular=rows end,
    showDiscoveryPage=function(_self,_tab,rows,options) home_render={books=rows,options=options} end,
    showTransientInfo=function(_self,message) home_notice=message end,
    refreshBookshelf=function(self,_view,options)
        self:applyShelfSnapshot(fresh,{})
        options.on_loaded(refresh_saved,{books=fresh,archives={}})
    end,
}, {__index=Discovery})
home:showHome();expect(home_render.books[1].bookId=='old','cached home setup failed')
home_render.options.on_refresh()
expect(home_render.books[1].bookId=='new','home refresh hid fresh books after cache failure')
expect(home_notice and home_notice:find('offline',1,true),'home refresh did not explain the cache failure')
refresh_saved=true;home_notice=nil;home:refreshHome()
expect(home_render.books[1].bookId=='new' and not home_notice,'successful refresh reported a cache failure')
print("discovery_spec: " .. checks .. " checks")
