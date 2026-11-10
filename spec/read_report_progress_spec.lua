-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
local last_read_options
local last_enter_options
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        make_enter_read_payload = function(options)
            last_enter_options = options
            return {
                kind = "enter",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
            }
        end,
        make_read_payload = function(options)
            last_read_options = options
            return {
                kind = "report",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
                elapsed_seconds = options.elapsed_seconds,
            }
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local function fixture(provider)
    local records = {}
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "auto",
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
    }
    local client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function() end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = function() return true end,
        subprocess = false,
        now = function() return 100 end,
    }
    return report, records
end

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("remote context merge rejects foreign or malformed reader progress", function()
    for _i, response in ipairs({
        { bookId = "other", progress = 90, chapterUid = 22, chapterOffset = 900, summary = "foreign" },
        { book = { bookId = "book", book_id = "other", progress = 90, chapterUid = 22 } },
        { bookId = "other", data = { book = { progress = 90, chapterUid = 22 } } },
        { book = { progress = 140, chapterUid = 22 } },
        { book = { progress = 25, chapterOffset = "bad" } },
        { errCode = -1, book = { progress = 25, chapterUid = 22 } },
        { data = { { progress = 25 }, { progress = 26 } } },
    }) do
        local report = fixture()
        report.client.get_progress = function() return response end
        local book = { book_id = "book", chapter_uid = 11, chapter_idx = 1, chapter_offset = 20,
            progress = 10, summary = "reader summary", psvts = "reader session" }
        report:_merge_remote_progress("book", book)
        eq(book.chapter_uid, 11, "unverified response cannot select a chapter")
        eq(book.chapter_idx, 1, "reader chapter index retained")
        eq(book.chapter_offset, 20, "reader offset retained")
        eq(book.progress, 10, "reader percentage retained")
        eq(book.summary, "reader summary", "reader summary retained")
        eq(book.psvts, "reader session", "reader session retained")
    end
end)

test("valid partial context merges preserve missing fields and accept explicit zero", function()
    local report = fixture()
    local book = { chapter_uid = 11, chapter_idx = 1, chapter_offset = 20, progress = 10, summary = "reader summary" }
    report.client.get_progress = function() return { book = { progress = 25 } } end
    report:_merge_remote_progress("book", book)
    eq(book.progress, 25, "validated percentage applied")
    eq(book.chapter_uid, 11, "missing chapter retained")
    eq(book.chapter_idx, 1, "missing chapter index retained")
    eq(book.chapter_offset, 20, "missing offset retained")
    eq(book.summary, "reader summary", "missing summary retained")
    report.client.get_progress = function()
        return { book = { bookId = "book", progress = 0, chapterUid = 0, chapterIdx = 0, chapterOffset = 0, summary = "" } }
    end
    report:_merge_remote_progress("book", book)
    eq(book.progress, 0, "explicit zero percent applied")
    eq(book.chapter_uid, 0, "explicit chapter zero applied")
    eq(book.chapter_idx, 0, "explicit index zero applied")
    eq(book.chapter_offset, 0, "explicit offset zero applied")
    eq(book.summary, "", "explicit empty summary applied")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 3, "enter plus two reports")
    eq(records[1].kind, "enter", "first request enters")
    eq(records[2].kind, "report", "second request reports")
    eq(records[2].chapter_uid, 22, "live chapter used")
    eq(records[2].chapter_offset, 150, "live offset used")
    eq(records[2].elapsed_seconds, 0, "progress-only report has zero time")
    eq(records[3].elapsed_seconds, 30, "time report keeps interval")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

test("source coordinates cannot enter the current reading-report protocol", function()
    local report = fixture()
    local book = { book_id = "book", psvts = "ps", pclts = "pc", token = "token" }
    report:_send("book", book, {
        chapter_uid = 22, chapter_idx = 2, chapter_offset = 150, percent = 25,
        retained_remote_target = true, viewport_fraction = 0.24,
        source_position = { chapter_uid = "22", chapter_offset = 12345, upload_verified = false },
    }, 0)
    eq(last_enter_options.chapter_offset, 150, "enter keeps existing wire offset")
    eq(last_read_options.chapter_offset, 150, "report keeps existing wire offset")
    eq(last_enter_options.source_position, nil, "enter excludes local source snapshot")
    eq(last_read_options.source_position, nil, "report excludes local source snapshot")
    eq(book.source_position, nil, "local source snapshot does not enter mutable report context")
    eq(last_read_options.retained_remote_target, nil, "local retention marker does not enter protocol")
    eq(last_read_options.viewport_fraction, nil, "native viewport metadata does not enter protocol")
end)

test('source upload guards each dispatch and never persists its source summary',function()
    for _i,mode in ipairs({'plain','before_context','after_context','after_enter'}) do
        local report=fixture()
        local valid,posts,persisted=true,0,nil
        report._auth_fingerprint=function() return 'synthetic-auth' end
        local book={book_id='book',psvts='ps',pclts='pc',token='token',summary='original context'}
        report.ensure_context=function()
            if mode=='after_context' then valid=false end
            return book
        end
        report._persist_context=function(_self,_id,snapshot) persisted=snapshot end
        report.client.report_read=function()
            posts=posts+1
            if mode=='after_enter' then valid=false end
            return {succ=1},200
        end
        report.client.get_web_progress=function() return {bookId='book',chapterUid=22,chapterIdx=2,chapterOffset=10000,progress=25} end
        local position={book_id='book',chapter_uid='22',chapter_idx=2,chapter_offset=10000,percent=25,summary='SOURCE_SUMMARY_CANARY'}
        local plan={position=position,basis='filtered_xhtml_utf16',is_current=function() return valid end}
        if mode=='before_context' then valid=false end
        local accepted,outcome=report:upload_position('book',position,0,plan)
        eq(accepted,mode=='plain','source upload outcome')
        eq(posts,mode=='plain' and 2 or mode=='after_enter' and 1 or 0,'stale source dispatched or retried')
        eq(book.summary,'original context','source summary mutated settings-owned book')
        if persisted then eq(persisted.summary,'original context','source summary entered persisted context') end
        if mode=='plain' then
            eq(last_read_options.chapter_offset,10000,'source co was changed at wire boundary')
            eq(last_read_options.summary,'SOURCE_SUMMARY_CANARY','actual source summary was not sent')
            eq(outcome.position_confirmed,true,'exact source readback was not confirmed')
        elseif mode=='after_enter' then eq(outcome.error_kind,'unconfirmed','partial dispatch was declared safe to repeat')
        else eq(outcome.error_kind,'position','zero sends were declared an unknown write') end
    end
end)

test('periodic source reports use only scalar child guards and never retry an uncertain send',function()
    for _i,mode in ipairs({'plain','expired','backwards','rotated','noack','transport'}) do
        local report=fixture()
        if mode=='backwards' then report.now=function() return 90 end end
        local posts,contexts,auth=0,0,'A'
        local book={book_id='book',psvts='ps',pclts='pc',token='token',summary='original context'}
        report._auth_fingerprint=function() return auth end
        report.ensure_context=function()
            contexts=contexts+1
            if mode=='rotated' then auth='B' end
            return book
        end
        report.client.report_read=function()
            posts=posts+1
            if mode=='transport' then error('synthetic transport') end
            return mode=='noack' and {} or {succ=1},200
        end
        local position={book_id='book',chapter_uid='22',chapter_idx=2,chapter_offset=10000,percent=25,summary='SOURCE_SUMMARY_CANARY'}
        local outcome=report:_run_pipeline('book',{position=position,source_deadline=mode=='expired' and 99 or 130,allow_renewal=true})
        eq(outcome.accepted,mode=='plain','periodic source outcome')
        eq(contexts,1,'source report refreshed or retried context')
        eq(posts,mode=='plain' and 2 or (mode=='noack' or mode=='transport') and 1 or 0,'source report retried a send')
        eq(book.summary,'original context','child source summary mutated settings context')
        eq(outcome.book.summary,'original context','child source summary entered parent outcome')
        eq(outcome.renew_attempted,false,'source report tried authorization renewal')
        if mode=='plain' then eq(last_read_options.elapsed_seconds,30,'source report lost periodic reading duration') end
        local uncertain=0
        report.on_source_unconfirmed=function() uncertain=uncertain+1 end
        report:_apply_outcome(outcome)
        eq(uncertain,(mode=='noack' or mode=='transport') and 1 or 0,'parent did not revoke unknown source write authority')
    end
end)

test('periodic preparation waits asynchronously and ignores a result after stop',function()
    local report=fixture(function() return {book_id='book',chapter_uid=22,chapter_offset=7,percent=25},nil,true end)
    local ready,dispatched
    report.position_preparer=function(_intent,callback) ready=callback end
    report._dispatch_tick=function(_self,_generation,_task,_book,position,deadline) dispatched={position=position,deadline=deadline} end
    report:start('fixture');report:_tick(report.generation,report.task)
    eq(dispatched,nil,'preparation dispatched synchronously')
    local plan={position={book_id='book',chapter_uid='22',chapter_offset=10000},deadline=130,is_current=function() return true end}
    ready(plan)
    eq(dispatched.position.chapter_offset,10000,'prepared periodic result used estimate')
    eq(dispatched.deadline,130,'worker source expiry was discarded')
    dispatched=nil;report:_tick(report.generation,report.task)
    report:stop('document_close');ready(plan)
    eq(dispatched,nil,'closed preparation dispatched a report')
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
