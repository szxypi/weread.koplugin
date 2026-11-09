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
local saved_catalogs = 0
local catalog = { { chapterUid = 1, chapterIdx = 1, title = "One", wordCount = 100 },
    { chapterUid = 2, chapterIdx = 2, title = "Two", wordCount = 100 } }
package.preload["weread.lib.content"] = function() return {
    ensure_reader_state = function(_client, book)
        book.token = "private-synthetic-token"
        return { progress = { chapterUid = 2 }, current_chapter = { chapterUid = 1 } }
    end,
    fetch_catalog = function() return catalog end,
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
print(("book_reading_spec: %d checks"):format(checks))
