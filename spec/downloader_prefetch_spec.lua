-- Focused tests for the downloader's single-prefetch invariant and promotion.

package.path = "./?.lua;" .. package.path

local scheduled = {}
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return { ensure_reader_state = function() end }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            options.show = function() end
            options.reportProgress = function() end
            options.close = function() end
            return options
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end

local Downloader = require("weread.lib.downloader")
local BookStore = require("weread.lib.book_store")
local Access = require("weread.lib.read_access")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local completions = {}
local function fake_settings()
    local values = { cache = {}, books = {} }
    return {
        is_cookie_configured = function() return true end,
        get = function(_self, key, default)
            return values[key] == nil and default or values[key]
        end,
        set = function(_self, key, value) values[key] = value end,
        record_download = function(_self, id, book, change)
            local record, conflict, legacy = Access.cached_book_for_update(values.books, id)
            if conflict then return false, "book_identity_conflict" end
            record = record or { book_id = book.book_id or book.bookId }
            BookStore.apply_download(record, change)
            if legacy then values.books[legacy] = nil end
            values.books[id] = record
            return true, record
        end,
        flush = function() end,
    }
end
local function fake_worker()
    local worker = { starts = {}, events = {} }
    worker.available = function() return true end
    worker.start = function(self, options)
        local handle = { options = options }
        self.starts[#self.starts + 1] = handle
        if options.on_launch then options.on_launch(100 + #self.starts, 96 * 1024) end
        return true, handle
    end
    worker.cancel = function(self, handle, reason)
        self.events[#self.events + 1] = function()
            handle.options.on_done { ok = false, cancelled = true, error = reason }
        end
        return true
    end
    return worker
end
local function run_scheduled()
    local callback = table.remove(scheduled, 1)
    if callback then callback() end
end
local function run_worker_event(worker)
    local callback = table.remove(worker.events, 1)
    if callback then callback() end
end

local worker = fake_worker()
local downloader = Downloader:new{
    client = {},
    settings = fake_settings(),
    background_worker = worker,
    is_connected = function() return true end,
    show_transient = function() end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
}

local book_a = { book_id = "a" }
local chapter_2 = { chapterUid = 2 }
local chapter_3 = { chapterUid = 3 }

expect(downloader:start(book_a, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
    on_complete = function(ok, reason)
        completions[#completions + 1] = { ok, reason }
    end,
}), "first prefetch starts")
expect(#scheduled == 1 and #worker.starts == 0,
    "first prefetch defers the worker launch so the UI can paint")
run_scheduled()
expect(#worker.starts == 1, "first prefetch starts one worker")
expect(worker.starts[1].options.kind == "chapter"
        and worker.starts[1].options.replace_active == true,
    "chapter prefetch did not identify its replaceable worker kind")
expect(downloader:isPrefetching(book_a, chapter_2), "first target is active")
expect(downloader:promotePrefetch(book_a, chapter_2), "matching prefetch promotes")
expect(downloader._active_job.open_on_complete == true,
    "promotion requests automatic open")
expect(downloader._active_job.progress_dialog ~= nil,
    "promotion exposes the background task progress")
expect(downloader:isPromotedPrefetch(book_a, chapter_2),
    "promoted target can be detected by navigation")
expect(not downloader:promotePrefetch(book_a, chapter_3),
    "different chapter cannot promote")

expect(downloader:start(book_a, { chapter_3 }, "chapter", {
    prefetch = true,
    single_chapter = true,
}), "replacement prefetch is queued")
expect(downloader._active_job.cancelled == true,
    "old prefetch is cancelled before replacement")
expect(downloader._pending_start.chapters[1] == chapter_3,
    "only replacement target is pending")

run_worker_event(worker)
expect(#scheduled == 1, "replacement schedules exactly one downloader start")
run_scheduled()
expect(#scheduled == 1, "replacement keeps the UI paint delay")
run_scheduled()
expect(#worker.starts == 2, "replacement creates one new worker")
expect(downloader:isPrefetching(book_a, chapter_3),
    "replacement becomes the sole active prefetch")
expect(#completions == 1 and completions[1][2] == "replaced",
    "cancelled prefetch reports replacement reason once")

downloader:cancelPrefetch("document_closed")
expect(downloader._active_job.cancelled == true,
    "document close cancels active prefetch")
run_worker_event(worker)
expect(downloader._active_job == nil,
    "cancelled worker completion clears the active prefetch")

scheduled = {}
local race_worker = fake_worker()
local race = Downloader:new{
    client = {},
    settings = fake_settings(),
    background_worker = race_worker,
    is_connected = function() return true end,
    show_transient = function() end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
}
race:start(book_a, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
})
race:start(book_a, { chapter_3 }, "chapter", {
    prefetch = true,
    single_chapter = true,
})
run_scheduled()
expect(#scheduled == 1 and race._scheduled_start ~= nil,
    "replacement waits in a cancellable scheduled slot")
race:cancelPrefetch("document_closed")
run_scheduled()
expect(#race_worker.starts == 0 and race._active_job == nil,
    "document close prevents the scheduled replacement from starting")

scheduled = {}
local starts_notified = 0
local deferred_worker = fake_worker()
local deferred = Downloader:new{
    client = {},
    settings = fake_settings(),
    background_worker = deferred_worker,
    is_connected = function() return true end,
    show_transient = function() end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
}
expect(deferred:start({ book_id = "b" }, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
    start_delay = 0.7,
    on_start = function() starts_notified = starts_notified + 1 end,
}), "deferred prefetch starts")
expect(starts_notified == 1 and #scheduled == 1,
    "start notice runs before initialization is scheduled")
expect(deferred._active_job.standby_guard == nil,
    "network initialization has not begun while notice is visible")
run_scheduled()
expect(deferred._active_job.standby_guard == true,
    "subprocess launch acquires standby after the notice grace period")
expect(#deferred_worker.starts == 1,
    "deferred prefetch performs work in the subprocess runner")

local temp_path=os.tmpname()
local temp_file=assert(io.open(temp_path,'wb'));temp_file:write('synthetic');temp_file:close()
for _,valid in ipairs({true,false}) do
    local opened,completed=0,0
    local test_book={book_id='a'}
    local instance=Downloader:new{settings=fake_settings(),refresh_shelf=function() end,
        open_file=function() opened=opened+1 end}
    local job={book=test_book,chapters={chapter_2},prefetch=true,prefetch_book_id='a',prefetch_chapter_uid='2',promoted=true,open_on_complete=true,
        promotion_current=function() return valid end,on_complete=function(ok) if ok then completed=completed+1 end end}
    instance._active_job=job
    instance:_applyPrefetchResult(job,{ok=true,value={path=temp_path,book_id='a',chapter_uid='2'}})
    expect(completed==1 and opened==(valid and 1 or 0) and test_book.cached_chapters['2']==temp_path,
        'late promoted prefetch did not cache safely or opened a stale selection')
end
do
    local foreign={title='other legacy book',cached_chapters={['1']='/original.epub'}}
    local books={[9007199254740992]=foreign}
    local settings=fake_settings();settings:set('books',books)
    local instance=Downloader:new{settings=settings,refresh_shelf=function() end}
    local job={book={book_id='9007199254740993'},chapters={chapter_2},prefetch=true,
        prefetch_book_id='9007199254740993',prefetch_chapter_uid='2'}
    instance._active_job=job
    instance:_applyPrefetchResult(job,{ok=true,value={path=temp_path,book_id='9007199254740993',chapter_uid='2'}})
    expect(foreign.cached_chapters['2']==nil and foreign.title=='other legacy book'
        and books['9007199254740993']~=foreign and books['9007199254740993'].book_id=='9007199254740993',
        'large book ID aliased a different legacy cache during prefetch')
end
do
    local legacy={book_id='42',title='legacy',cached_chapters={}}
    local books={[42]=legacy};local settings=fake_settings();settings:set('books',books)
    local instance=Downloader:new{settings=settings,refresh_shelf=function() end}
    local job={book={book_id='42'},chapters={chapter_2},prefetch=true,prefetch_book_id='42',prefetch_chapter_uid='2'};instance._active_job=job
    instance:_applyPrefetchResult(job,{ok=true,value={path=temp_path,book_id='42',chapter_uid='2'}})
    expect(books['42']==legacy and books[42]==nil and legacy.cached_chapters['2']==temp_path,
        'prefetch lost a safe legacy numeric book key')
end
do
    local conflict={book_id='99',title='different book',cached_chapters={['1']='/original.epub'}}
    local books={['42']=conflict};local settings=fake_settings();settings:set('books',books)
    local reason,refreshed
    local instance=Downloader:new{settings=settings,refresh_shelf=function() refreshed=true end}
    local worker_settings=require('weread.lib.worker_settings');local original_merge=worker_settings.merge;local merges=0
    worker_settings.merge=function() merges=merges+1;return true end
    local job={book={book_id='42'},chapters={chapter_2},prefetch=true,prefetch_book_id='42',prefetch_chapter_uid='2',
        on_complete=function(ok,value) if not ok then reason=value end end}
    instance._active_job=job;instance:_applyPrefetchResult(job,{ok=true,value={path=temp_path,book_id='42',chapter_uid='2',auth={}}})
    worker_settings.merge=original_merge
    expect(reason=='book_identity_conflict' and not refreshed and not instance._active_job
        and merges==0 and books['42']==conflict and conflict.cached_chapters['2']==nil and job.book.cached_chapters==nil,
        'prefetch changed a cache entry with a conflicting book identity')
end
for _,change in ipairs({'book','chapter','worker_book','worker_chapter','missing_worker_book'}) do
    local settings=fake_settings();local book={book_id='42'};local chapter={chapterUid='2'}
    local result={path=temp_path,chapter_uid='2',book_id='42'};local reason
    local instance=Downloader:new{settings=settings,refresh_shelf=function() error('stale result refreshed shelf') end}
    local job={book=book,chapters={chapter},prefetch=true,prefetch_book_id='42',prefetch_chapter_uid='2',
        on_complete=function(ok,value) if not ok then reason=value end end}
    if change=='book' then book.book_id='99'
    elseif change=='chapter' then chapter.chapterUid='3'
    elseif change=='worker_book' then result.book_id='99'
    elseif change=='worker_chapter' then result.chapter_uid='3'
    else result.book_id=nil end
    instance._active_job=job
    local ok=pcall(instance._applyPrefetchResult,instance,job,{ok=true,value=result})
    expect(ok and reason=='book_identity_conflict' and not instance._active_job and not book.cached_chapters
        and next(settings:get('books',{}))==nil,'stale prefetch result was linked after '..change..' changed')
end
os.remove(temp_path)
for _,case in ipairs({{'book_reading/web_expired\nstack traceback:','web_expired'},
    {'download_read/rate_limited\nstack traceback:','rate_limited'},
    {'native_candidate/auth_expired\nstack traceback:','native_auth_expired'},
    {'native_candidate/service_rejected\nstack traceback:','native_resource_failed'},
    {'native_candidate/session_changed\nstack traceback:','account_changed'}}) do
    local reason
    local instance=Downloader:new{settings=fake_settings()}
    local job={book=book_a,chapters={chapter_2},prefetch=true,on_complete=function(_,value) reason=value end}
    instance._active_job=job;instance:_applyPrefetchResult(job,{ok=false,error=case[1]})
    expect(reason==case[2] and not instance._active_job,'prefetch failed to normalize a known HTTP condition')
end
for _,change in ipairs({'epoch','credentials'}) do
    scheduled={}
    local state_epoch=1
    local owned=fake_settings()
    owned.get_auth_scope=function() return {vid='900000',epoch=state_epoch} end
    owned.auth_scope_matches=function(_,scope) return scope.epoch==state_epoch end
    local check_worker=fake_worker()
    local completed,opened=nil,0
    local instance=Downloader:new{client={},settings=owned,background_worker=check_worker,
        is_connected=function() return true end,refresh_shelf=function() end,refresh_ui=function() end,
        open_file=function() opened=opened+1 end}
    local scoped_book={book_id='a'}
    instance:start(scoped_book,{chapter_2},'chapter',{prefetch=true,single_chapter=true,
        on_complete=function(_,reason) completed=reason end})
    if change=='epoch' then state_epoch=2 else owned:set('cookies',{wr_skey='new-session'}) end
    run_scheduled()
    expect(#check_worker.starts==0 and completed=='account_changed' and not instance._active_job,
        'changed '..change..' launched a stale prefetch')

    state_epoch=1;owned:set('cookies',{});completed=nil
    instance:start(scoped_book,{chapter_2},'chapter',{prefetch=true,single_chapter=true,
        on_complete=function(_,reason) completed=reason end})
    run_scheduled();instance:promotePrefetch(scoped_book,chapter_2,function() return true end)
    if change=='epoch' then state_epoch=2 else owned:set('cookies',{wr_skey='new-session'}) end
    local file_path=os.tmpname();local handle=assert(io.open(file_path,'wb'));handle:write('old');handle:close()
    check_worker.starts[#check_worker.starts].options.on_done{ok=true,value={path=file_path,chapter_uid='2'}}
    expect(completed=='account_changed' and opened==0 and not scoped_book.cached_chapters and not instance._active_job,
        'changed '..change..' accepted a stale prefetch result')
    os.remove(file_path)
end
local native_current=true
local native_grant={fingerprint='native-grant'}
package.loaded['weread.lib.native_read_access']={
    capture=function() return native_grant end,
    matches=function(_,value) return native_current and value==native_grant end,
}
for _,when in ipairs({'before_launch','before_result'}) do
    scheduled={};native_current=true
    local owned=fake_settings()
    owned:set('cache',{download_book_images=true,native_chapter_resources=true})
    local check_worker=fake_worker()
    local completed,opened=nil,0
    local instance=Downloader:new{client={},settings=owned,background_worker=check_worker,
        is_connected=function() return true end,refresh_shelf=function() end,refresh_ui=function() end,
        open_file=function() opened=opened+1 end}
    local scoped_book={book_id='a'}
    instance:start(scoped_book,{chapter_2},'chapter',{prefetch=true,single_chapter=true,
        on_complete=function(_,reason) completed=reason end})
    if when=='before_launch' then native_current=false end
    run_scheduled()
    if when=='before_result' then
        expect(#check_worker.starts==1,'native prefetch did not launch')
        instance:promotePrefetch(scoped_book,chapter_2,function() return true end)
        native_current=false
        check_worker.starts[1].options.on_done{ok=true,value={path='/unused'}}
    end
    expect(completed=='account_changed' and opened==0 and not scoped_book.cached_chapters
        and not instance._active_job,'changed native grant accepted a stale prefetch '..when)
end
for _,key in ipairs({'download_book_images','native_chapter_resources'}) do
for _,when in ipairs({'before_launch','before_result'}) do
    scheduled={};native_current=true
    local owned=fake_settings()
    local cache={download_book_images=true,native_chapter_resources=true};owned:set('cache',cache)
    local check_worker=fake_worker()
    local completed
    local instance=Downloader:new{client={},settings=owned,background_worker=check_worker,
        is_connected=function() return true end,refresh_shelf=function() end,refresh_ui=function() end}
    instance:start({book_id='a'},{chapter_2},'chapter',{prefetch=true,single_chapter=true,
        on_complete=function(_,reason) completed=reason end})
    if when=='before_launch' then cache[key]=false end
    run_scheduled()
    if when=='before_result' then
        cache[key]=false
        check_worker.starts[1].options.on_done{ok=true,value={path='/unused'}}
    end
    expect(completed=='setting_disabled' and not instance._active_job,
        'disabled '..key..' accepted a native prefetch '..when)
end
end
local queued=Downloader:new{settings=fake_settings()}
queued._active_job={prefetch=true,cancelled=true}
queued._pending_start={book=book_a,chapters={chapter_2},options={prefetch=true}}
expect(queued:cancelPrefetch('suspended') and not queued._pending_start,
    'suspend failed to report a cancelled queued prefetch')

print(string.format(
    "downloader_prefetch_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
