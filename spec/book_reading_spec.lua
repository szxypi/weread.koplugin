package.path = "./?.lua;" .. package.path
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local tasks = {}
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self, delay, task)
        expect(delay >= 0.1, "blocking scheduling delay"); tasks[#tasks + 1] = task
    end }
end
package.preload["weread.lib.plugin_util"] = function() return { tr = function(text) return text end } end
local saved_catalogs,source_version = 0,0
local catalog = { { chapterUid = 1, chapterIdx = 1, title = "One", wordCount = 100 },
    { chapterUid = 2, chapterIdx = 2, title = "Two", wordCount = 100 } }
package.preload["weread.lib.content"] = function() return {
    ensure_reader_state = function(_client, book)
        book.token = "private-synthetic-token"
        return { progress = { chapterUid = 2 }, current_chapter = { chapterUid = 1 } }
    end,
    fetch_catalog = function() return catalog,source_version end,
    save_catalog_cache = function() saved_catalogs = saved_catalogs + 1; return true end,
} end
local Reading = require("weread.ui.book_reading")
local projected = assert(Reading.catalog(catalog))
expect(projected[1].chapterUid == "1", "chapter ID normalization")
local raw = { { chapterUid = 1, title = "One", token = "private", wordCount = 4 } }
expect(Reading.catalog(raw)[1].token == nil, "catalog retained private fields")
for _, invalid in ipairs({ {}, { {} }, { { chapterUid = 1, title = "Bad\nTitle" } },
    { raw[1], raw[1] }, { { chapterUid = "../1", title = "Bad" } } }) do
    expect(not Reading.catalog(invalid), "invalid catalog accepted")
end
expect(Reading.choose(projected, {}, { chapter_uid = 2 }) == projected[2], "cloud chapter ignored")
expect(Reading.choose(projected, { chapter_uid = 1 }, { chapter_uid = 2 }) == projected[1], "local chapter lost")
expect(Reading.choose(projected, { chapter_uid = 1, pending_upload_position = { chapter_uid = 2 } }) == projected[2],
    "pending local progress lost")
expect(Reading.choose(projected, { chapter_idx = 2 }) == projected[2], "chapter index ignored")
expect(Reading.choose(projected, { progress = 99 }) == projected[1], "percentage guessed a chapter")
for _i,position in ipairs({{chapter_uid=2},{chapter_idx=2},{chapter_uid=999,chapter_idx=2}}) do
    expect(Reading.choose(projected,{book_id='900001',chapter_uid=1,pending_upload_account='owner',
        pending_upload_position=position},nil,'owner')==projected[2],'same-account pending chapter did not win')
end
for _i,change in ipairs({{pending_upload_account='other'},
    {pending_upload_position={book_id='900002',chapter_uid=2}},
    {pending_upload_position={bookId='900002',chapter_uid=2}},
    {pending_upload_position={chapter_idx=0/0}}, {pending_upload_position='invalid'}}) do
    local candidate={book_id='900001',chapter_uid=1,pending_upload_account='owner',pending_upload_position={chapter_uid=2}}
    for key,value in pairs(change) do candidate[key]=value end
    expect(Reading.choose(projected,candidate,nil,'owner')==projected[1],'foreign or malformed pending chapter was used')
end
expect(Reading.resume_index(projected,{chapter_uid=1,last_local_position={chapter_uid=2}})==2,
    'last local chapter lost to refreshed book metadata')
expect(Reading.resume_index(projected,{chapter_uid=1,recent_read_account='other',last_local_position={chapter_uid=2}},nil,'owner')==1,
    'foreign last local chapter was used')
expect(Reading.resume_index(projected,{chapter_uid=1,recent_read_account='owner',last_local_account='other',
    last_local_position={chapter_uid=2}},nil,'owner')==1,'recent event transferred a foreign last local position')
expect(Reading.resume_index(projected,{chapter_uid=1,recent_read_account='other',last_local_account='owner',
    last_local_position={chapter_uid=2}},nil,'owner')==2,'explicit local-position owner was ignored')
expect(Reading.resume_index(projected,{chapter_uid=1,recent_read_account='owner',last_local_account='',
    last_local_position={chapter_uid=2}},nil,'owner')==1,'unowned local position inherited a legacy owner')
local duplicates = assert(Reading.catalog({
    { chapterUid=1, chapterIdx=0, title='One' },
    { chapterUid=2, chapterIdx=0, title='Two' },
    { chapterUid=3, chapterIdx=3, title='Three' },
}))
expect(Reading.resume_index(duplicates,{pending_upload_position={chapter_idx=0},
    last_local_position={chapter_uid=2}},nil,'owner')==2,
    'ambiguous pending index masked the last local chapter')
expect(Reading.resume_index(duplicates,{pending_upload_position={chapter_uid=999,chapter_idx=0},
    last_local_position={chapter_uid=2}},nil,'owner')==2,
    'missing UID with ambiguous index masked the last local chapter')
expect(Reading.resume_index(duplicates,{pending_upload_position={chapter_uid=2,chapter_idx=0},
    last_local_position={chapter_uid=3}},nil,'owner')==2,
    'unique UID did not take precedence over duplicate indices')
expect(Reading.resume_index(duplicates,{pending_upload_position={chapter_idx=0}},
    {chapter_uid=3},'owner')==3,'ambiguous index masked the remote chapter')
expect(Reading.resume_index(duplicates,{pending_upload_position={chapter_idx=0}},nil,'owner')==nil,
    'ambiguous index was treated as an exact chapter')
expect(Reading.resume_index(duplicates,{pending_upload_position={chapter_idx=3}},nil,'owner')==3,
    'unique index did not remain usable')
expect(Reading.resume_uid(nil,{book_id='900001',pending_upload_position={book_id='900001',chapter_uid=9}},'owner')=='9',
    'missing catalog discarded the pending UID')
expect(Reading.resume_uid(projected,{book_id='900001',pending_upload_position={chapter_idx=1},
    last_local_position={chapter_uid=2}},'owner')=='1','unique pending index lost precedence over later UID')
expect(Reading.resume_uid(duplicates,{pending_upload_position={chapter_idx=0},last_local_position={chapter_uid=2}},'owner')=='2',
    'ambiguous index masked later UID')
expect(Reading.resume_uid(projected,{book_id='900001',pending_upload_account='other',
    pending_upload_position={chapter_uid=1},last_local_position={chapter_uid=2}},'owner')=='2',
    'foreign pending UID was selected')

local function fixture()
    tasks, saved_catalogs = {}, 0
    local state = { owner = "a", online = true, auth = true, login = true, epoch = 1, downloads = 0, errors = 0,
        cancellations = 0, catalog_writes = 0, opened = 0 }
    local cookies = { wr_vid = "900000", wr_skey = "synthetic-web-access" }
    local books = { ["900001"] = { book_id = "900001", title = "Latest title", pending_upload_position = { chapter_uid = 1 } } }
    local host = { discovery_epoch = 1, client = {}, settings = {
        get = function(_self, key, fallback) if key == "cookies" then return cookies end; return fallback end,
        get_book = function(_self, id) return books[id] end,
        get_auth_scope = function() return { vid = "900000", epoch = state.epoch } end,
        auth_scope_matches = function(_self, scope) return state.auth and scope.epoch == state.epoch end,
        flush = function() end,
    }, library_db = {
        accountKey = function() return state.owner end,
        putChapters = function() state.catalog_writes = state.catalog_writes + 1; return true end,
    }, isNetworkOnline = function() return state.online end,
        requireLogin = function() return state.login end,
        showOffline = function() state.errors = state.errors + 1 end,
        showInfo = function() state.errors = state.errors + 1 end,
        showBusy = function(self, _label, cancel) self.busy_message = {}; state.cancel = cancel end,
        closeBusy = function(self) self.busy_message = nil end,
        openFile = function(_self, path) state.opened = state.opened + 1; state.path = path end,
        book_reading_worker = {
            start = function(_self, task, complete) state.job = { task = task, complete = complete }; return true end,
            cancel = function() state.cancellations = state.cancellations + 1 end,
        }, downloader = {
            start = function(_self, book, chapters, suffix, options)
                state.downloads = state.downloads + 1
                state.download = { book = book, chapter = chapters[1], suffix = suffix, options = options }
                return true
            end,
            cancelRequest = function(_self, complete)
                if state.download then expect(complete == state.download.options.on_complete, "cancelled another download") end
            end,
        } }
    return host, state, cookies, books
end
local book = { book_id = "900001", title = "Old title" }
local host, state = fixture()
local guest_view={};local intent,resumed_book
state.owner=nil;state.login=false;host._book_detail_view=guest_view;host.ui={}
host.settings.get_auth_scope=function() return nil end
host.requireLogin=function(_self,_cookie,_key,value) intent=value;return false end
host.startBookReading=function(_self,value) resumed_book=value end
expect(not Reading.start(host,book,guest_view) and intent and intent.current(),'guest read lost login intent')
intent.resume()
expect(resumed_book.book_id=='900001' and resumed_book.title==nil,'login continuation retained stale book state')
host._book_detail_view={};expect(not intent.current(),'closed guest detail retained login intent')
host._book_detail_view=guest_view;host.discovery_epoch=2;expect(not intent.current(),'changed page retained login intent')
host.discovery_epoch=1;state.owner='other';expect(not intent.current(),'new account retained guest login intent')
host,state=fixture()
state.owner=nil;state.login=false;host.ui={}
host.settings.get_auth_scope=function() return nil end
host.requireLogin=function(_self,_cookie,_key,value) intent=value;return false end
host.startBookReading=function(_self,value) resumed_book=value end
local page_current=true
local origin={current=function() return page_current end}
local public_book={bookId='900001',title='Public title',author='Public author',chapter_uid='123',cached_file='/foreign'}
expect(not Reading.start(host,public_book,nil,origin) and intent and intent.current(),
    'guest quick read lost its login intent')
public_book.title='Changed later';intent.resume()
expect(resumed_book.book_id=='900001' and resumed_book.title=='Public title' and resumed_book.author=='Public author'
    and not resumed_book.chapter_uid and not resumed_book.cached_file,'guest continuation retained mutable or local state')
page_current=false;expect(not intent.current(),'replaced guest page retained its login intent')
expect(not Reading.start(host,public_book,nil,origin),'stale quick-read page started a request')
host,state=fixture();page_current=true
expect(Reading.start(host,book,nil,origin),'current quick read did not start')
page_current=false;state.job.complete(state.job.task())
expect(state.downloads==0 and not host.book_reading_context,'stale quick-read worker downloaded a book')
host,state=fixture()
expect(Reading.start(host, book), "reading preparation did not start")
expect(state.downloads == 0 and host.busy_message, "network preparation blocked or skipped busy UI")
local result = state.job.task()
expect(result.remote.chapter_uid == 2 and result.token == nil, "worker leaked context or chose page chapter over cloud progress")
state.job.complete(result)
expect(state.downloads == 1 and state.download.chapter.chapterUid == "1" and state.download.book.title == "Latest title",
    "preparation overwrote current saved data")
expect(saved_catalogs == 1 and state.catalog_writes == 1 and not host.busy_message, "catalog was not persisted in parent")
expect(state.download.options.single_chapter and state.download.options.silent_completion and not state.download.options.offer_read,
    "read required another completion dialog")
state.download.options.on_complete(true, "/cache/chapter.epub")
expect(state.opened == 0, "opened before downloader released its job")
tasks[1]()
expect(state.path == "/cache/chapter.epub" and not host.book_reading_context, "native reader was not opened")

do
    local previous=catalog
    catalog={{chapterUid=1,chapterIdx=0,title='One'}, {chapterUid=2,chapterIdx=0,title='Two'},
        {chapterUid=3,chapterIdx=3,title='Three'}}
    local test_host,test_state,_,books=fixture()
    books['900001'].pending_upload_position={chapter_idx=0}
    books['900001'].last_local_position={chapter_uid=2}
    expect(Reading.start(test_host,book),'ambiguous online reading preparation did not start')
    test_state.job.complete(test_state.job.task())
    expect(test_state.download and test_state.download.chapter.chapterUid=='2',
        'online reading downloaded the first duplicate index instead of the last local chapter')
    Reading.cancel(test_host)
    catalog=previous
end

for _, change in ipairs({ "cancel", "view", "account", "session", "cookie", "navigation" }) do
    local cookies
    host, state, cookies = fixture()
    local view = {}; host._book_detail_view = view
    Reading.start(host, book, view)
    result = state.job.task()
    if change == "cancel" then state.cancel()
    elseif change == "view" then host._book_detail_view = {}
    elseif change == "account" then state.owner = "b"
    elseif change == "session" then state.epoch = 2
    elseif change == "cookie" then cookies.wr_skey = "new-synthetic-access"
    else host.discovery_epoch = 2 end
    state.job.complete(result)
    expect(state.downloads == 0 and saved_catalogs == 0 and not host.book_reading_context and not host.busy_message,
        "stale preparation committed: " .. change)
end
host, state = fixture()
Reading.start(host, book); local old = state.job
Reading.start(host, book); local replacement = host.book_reading_context
old.complete(old.task())
expect(host.book_reading_context == replacement and state.downloads == 0, "old callback cancelled replacement")
for _, change in ipairs({ "cancel", "session", "navigation" }) do
    host, state = fixture(); Reading.start(host, book); state.job.complete(state.job.task())
    local complete = state.download.options.on_complete
    complete(true, "/cache/stale.epub")
    if change == "cancel" then Reading.cancel(host)
    elseif change == "session" then state.epoch = 2
    else host.discovery_epoch = 2 end
    tasks[1]()
    expect(state.opened == 0 and not host.book_reading_context, "late download opened: " .. change)
end
for _, change in ipairs({ "offline", "login", "worker", "catalog", "storage", "download" }) do
    host, state = fixture()
    if change == "offline" then state.online = false
    elseif change == "login" then state.login = false
    elseif change == "worker" then host.book_reading_worker.start = function() return false end
    elseif change == "storage" then host.library_db.putChapters = function() return false end
    elseif change == "download" then host.downloader.start = function() return false end end
    Reading.start(host, book)
    if state.job then state.job.complete(change == "catalog" and {} or state.job.task()) end
    expect(not host.book_reading_context and not host.busy_message and state.opened == 0, "failure retained task: " .. change)
end
host,state=fixture()
local cb_book={book_id='CB_SyntheticReading',title='CB title'}
expect(Reading.start(host,cb_book),'verified CB reading did not start')
result=state.job.task();state.job.complete(result)
expect(result.book_id==cb_book.book_id and state.download.book.book_id==cb_book.book_id
    and state.downloads==1,'CB reading did not reach the normal chapter downloader')
state.download.options.on_complete(true,'/cache/cb.epub');tasks[1]()
expect(state.path=='/cache/cb.epub','CB download did not open the native reader')
for _i,id in ipairs({'CB_','CB_'..string.rep('a',65),'CB_a/b','CB_a_b','MP_WXS_synthetic'}) do
    host,state=fixture()
    expect(not Reading.start(host,{book_id=id}) and not state.job and state.downloads==0,'invalid CB reading started work')
end
-- A fresh catalogue version belongs only to the new download, never the
-- mutable book record or existing cache/ledger identity.
source_version=7;host,state=fixture()
local latest=host.settings:get_book('900001');latest.bookVersion=99;latest.cached_file='/cache/old-source.epub'
Reading.start(host,book);result=state.job.task();expect(result.source_version==7,'worker dropped observed source version')
state.job.complete(result)
expect(state.download.book.bookVersion==7 and latest.bookVersion==99,'new source reused shelf version or relabelled old cache')
expect(state.download.book~=latest and latest.cached_file=='/cache/old-source.epub','new download mutated the existing source record')
state.download.options.on_complete(true,'/cache/new-source.epub');tasks[1]()
for _i,value in ipairs({true,'7',-1,2147483648,1.5}) do
    host,state=fixture();Reading.start(host,book);result=state.job.task();result.source_version=value;state.job.complete(result)
    expect(state.downloads==0 and not host.busy_message,'malformed source version reached downloader')
end
source_version=0;host,state=fixture();Reading.start(host,book);state.job.complete(state.job.task())
expect(state.download.book.bookVersion==0,'missing catalogue version fell back to display metadata')
print(("book_reading_spec: %d checks"):format(checks))
