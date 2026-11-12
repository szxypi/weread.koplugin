-- Unit tests for weread/lib/progress_sync.lua.
-- Run from the repo root with:
--   lua spec/progress_sync_spec.lua

package.path = "./?.lua;" .. package.path
local ProgressSync = require("weread.lib.progress_sync")

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

-- Mirrors PULL_RETRY_DELAY_SECONDS in weread/lib/progress_sync.lua.
local PULL_RETRY_DELAY_SECONDS = 15

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600 },
}

local function fixture(remote, options)
    options = options or {}
    local document = {
        file = "/cache/book/full.epub",
        page = 25,
        getCurrentPage = function(self) return self.page end,
        getPageCount = function() return 100 end,
    }
    local book = {
        book_id = "book",
        title = "Book",
        summary = "Book",
        cached_file = document.file,
        cached_chapters = {
            ["11"] = document.file,
            ["22"] = document.file,
            ["33"] = document.file,
        },
    }
    local values = {
        account = { user_vid = "fixture-account-a" },
        sync = {
            pull_on_open = true,
            upload_on_close = true,
            ask_on_conflict = true,
        },
        books = { book = book },
    }
    local settings = {
        get = function(_self, key, default)
            return values[key] or default
        end,
        set = function(_self, key, value)
            values[key] = value
        end,
        flush = function() end,
        is_api_configured = function() return true end,
        is_cookie_configured = function() return true end,
    }
    local queue = {}
    local scheduler = {
        scheduleIn = function(_self, delay, callback)
            queue[#queue + 1] = { delay = delay, callback = callback }
        end,
    }
    local choices = {}
    local uploads = {}
    local jumps = {}
    local notifications = {}
    local client = {
        get_progress = function()
            return { book = remote }
        end,
        get_web_progress = function()
            return remote
        end,
    }
    local sync = ProgressSync:new{
        settings = settings,
        client = client,
        scheduler = scheduler,
        get_document = function() return document end,
        get_footer = options.get_footer,
        get_source_position = options.get_source_position,
        get_view_mode = options.get_view_mode,
        get_viewport_height = options.get_viewport_height,
        get_navigation_xpointer = options.get_navigation_xpointer,
        detect_book = function() return "book" end,
        get_book = function() return book end,
        get_chapters = options.get_chapters or function() return chapters end,
        refresh_catalog = options.refresh_catalog,
        get_file_context = function()
            return nil, nil, true
        end,
        run_online = options.run_online or function(_kind, callback)
            callback()
            return true
        end,
        upload_position = function(_book_id, position, elapsed)
            uploads[#uploads + 1] = position
            eq(elapsed, 0, "progress upload has zero reading time")
            return true, { accepted = true, position_confirmed = true, acknowledged = true }
        end,
        goto_fraction = function(fraction)
            jumps[#jumps + 1] = fraction
            document.page = math.floor(fraction * 100 + 0.5)
            return true
        end,
        open_chapter = function() return true end,
        on_choice = function(context)
            choices[#choices + 1] = context
        end,
        notify = function(code, data)
            notifications[#notifications + 1] = { code = code, data = data }
        end,
        is_online = options.is_online,
        now = options.now,
    }
    local function step()
        local entry = table.remove(queue, 1)
        if not entry then return false end
        entry.callback()
        return true
    end
    local function drain()
        local count = 0
        while #queue > 0 do
            count = count + 1
            assert(count < 20, "scheduler did not quiesce")
            step()
        end
    end
    return {
        sync = sync,
        document = document,
        values = values,
        choices = choices,
        uploads = uploads,
        jumps = jumps,
        notifications = notifications,
        queue = queue,
        client = client,
        step = step,
        drain = drain,
    }
end

test("malformed cloud rechecks revoke old authority without losing local intent", function()
    for _i, bad in ipairs({
        { bookId = "other", data = { progress = 25 } },
        { bookId = "book", book_id = "other", progress = 25 },
        { progress = 140 },
        { progress = 25, chapterOffset = "bad" },
        { errCode = -1, progress = 25 },
        { data = { { progress = 25 }, { progress = 26 } } },
    }) do
        local f = fixture({ progress = 25, chapterUid = 22, chapterIdx = 2, chapterOffset = 150 })
        f.sync:on_reader_ready(); f.drain()
        -- Use the real state machine to establish a prior accepted decision.
        if #f.choices > 0 then f.choices[#f.choices].keep_local() end
        eq(f.sync.verified, true, "initial comparison verified")
        f.document.page = 30; f.sync:on_page_update(); f.sync:checkpoint_local("test_flush")
        local pending = f.values.books.book.pending_upload_position
        local before = #f.uploads
        f.client.get_progress, f.client.get_web_progress = function() return bad end, function() return bad end
        assert(f.sync:sync_now()); f.drain()
        eq(f.sync.state, "error", "bad response is an error")
        eq(f.sync.verified, false, "old authority revoked")
        eq(f.values.books.book.pending_upload_position, pending, "local intent retained")
        eq(f.document.page, 30, "bad data did not navigate")
        eq(#f.uploads, before, "bad data did not upload")
        local position, reason = f.sync:position_for_report("book")
        eq(position, nil, "time reporter cannot reuse old verification")
        eq(reason, "progress_unverified", "reporter waits for a valid comparison")
    end
end)

test("new comparisons cancel queued writes and busy retries for the same book", function()
    for _i, busy in ipairs({ false, true }) do
        local callbacks, attempts = {}, 0
        local f = fixture({}, { run_online = function(_kind, callback)
            callbacks[#callbacks + 1] = callback; return true
        end })
        f.sync.upload_position = function()
            attempts = attempts + 1; return false, { error_kind = "busy" }
        end
        local position = assert(f.sync:capture_local())
        f.sync:_upload_snapshot(position, "manual_sync", true)
        if busy then callbacks[1]() end
        local pending = f.values.books.book.pending_upload_position
        assert(f.sync:sync_now())
        if busy then f.drain() else callbacks[1]() end
        callbacks[2]()
        eq(attempts, busy and 1 or 0, "replaced write never dispatches again")
        eq(f.sync.uploading, false, "old writer ownership released")
        eq(f.values.books.book.last_uploaded_position, nil, "no old acknowledgement")
        eq(f.values.books.book.pending_upload_position, pending, "queued local intent retained")
    end
end)

test("a unique valid source remains usable when the other source is malformed", function()
    for _i, bad_source in ipairs({ "web", "gateway" }) do
        local good = { progress = 25, chapterUid = 22, chapterIdx = 2, chapterOffset = 150 }
        local f = fixture(good)
        local bad = function() return { bookId = "other", data = good } end
        if bad_source == "web" then f.client.get_web_progress = bad else f.client.get_progress = bad end
        f.sync:on_reader_ready(); f.drain()
        eq(f.sync.verified, true, "valid source can verify the comparison")
        eq(f.sync.remote_position.source, bad_source == "web" and "gateway" or "web", "malformed source was ignored")
        eq(#f.choices, 0, "valid matching response needs no conflict choice")
        eq(#f.uploads, 0, "source fallback remains read-only")
    end
end)

test("page turns reuse word counts and document changes rebuild them", function()
    local word_reads = 0
    local function chapter(uid, words)
        return setmetatable({ chapterUid = uid }, { __index = function(_, key)
            if key == "wordCount" then
                word_reads = word_reads + 1
                return words
            end
        end })
    end
    local catalog = {}
    for index = 1, 5000 do catalog[index] = chapter(index, 10) end
    local f = fixture(nil, { get_chapters = function() return catalog end })
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready()
    f.drain()
    eq(word_reads, 5000, "opening builds one word-count catalog")
    for page = 26, 80 do
        f.document.page = page
        f.sync:on_page_update()
    end
    eq(word_reads, 5000, "page turns do not reread chapter word counts")
    eq(f.sync.local_position.chapter_uid, 4001, "page turn chapter")
    eq(f.sync.local_position.chapter_offset, 0, "page turn offset")

    catalog = { chapter(44, 200), chapter(55, 800) }
    f.document.page = 50
    f.sync.detect_book = function() return "other" end
    local position = assert(f.sync:capture_local())
    eq(word_reads, 5002, "changed book rebuilds catalog even at the same path")
    eq(position.book_id, "other", "fresh book detection is preserved")
    eq(position.chapter_uid, 55, "new book chapter")
    eq(position.chapter_offset, 300, "new book offset")

    f.document.file = "/cache/other/chapter.epub"
    f.sync.get_file_context = function() return 1, catalog[1], false end
    position = assert(f.sync:capture_local())
    eq(word_reads, 5004, "changed file rebuilds catalog")
    eq(position.chapter_uid, 44, "single chapter file")
    eq(position.chapter_offset, 100, "single chapter offset")
    eq(position.percent, 10, "single chapter overall progress")
    f.sync:on_close_document()
    eq(f.sync.document_context, nil, "close releases the document catalog")
    f.sync:on_reader_ready()
    f.drain()
    eq(word_reads, 5006, "reopen rebuilds catalog")
end)

test("matching open progress verifies the reporting gate", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "session verified")
    eq(#f.choices, 0, "no conflict dialog")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(applies, true, "provider applies")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
    eq(position.chapter_offset, 150, "live offset")
end)

test("nearby progress within two percent is treated as aligned", function()
    local f = fixture({
        bookId = "book",
        progress = 26.9,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 169,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "nearby position verifies")
    eq(#f.choices, 0, "nearby position does not prompt")
end)

test("unresolved conflict blocks reports and local choice uploads", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "conflict dialog requested")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position, nil, "position withheld")
    eq(reason, "progress_unverified", "gate reason")
    eq(applies, true, "provider applies")
    f.choices[1].keep_local()
    eq(f.sync:status().verified, true, "local choice verifies")
    eq(#f.uploads, 1, "local choice uploads immediately")
    eq(f.uploads[1].chapter_offset, 150, "uploaded immutable position")
end)

test("page change uploads once on close", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 50
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "page change marks dirty")
    f.sync:on_close_document()
    eq(#f.uploads, 1, "close uploads once")
    eq(f.uploads[1].percent, 50, "close uploads current percent")
    eq(f.uploads[1].chapter_uid, 33, "close uploads current chapter")
    eq(f.values.books.book.pending_upload_position, nil,
        "successful upload clears pending snapshot")
end)

test("remote choice jumps and verifies before reporting", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    f.drain()
    eq(#f.jumps, 1, "one jump")
    eq(f.jumps[1], 0.5, "jump fraction")
    eq(f.sync:status().verified, true, "remote choice verifies")
    local position = f.sync:position_for_report("book")
    eq(position.percent, 50, "report sees jumped position")
end)

test("busy read report is retried with the immutable snapshot", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    local attempts = 0
    local uploaded
    f.sync.upload_position = function(_book_id, position)
        attempts = attempts + 1
        if attempts == 1 then
            return false, { error = "busy", error_kind = "busy" }
        end
        uploaded = position
        return true, { accepted = true, position_confirmed = true, acknowledged = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].keep_local()
    -- Mutating the live page must not change the already captured retry.
    f.document.page = 75
    f.drain()
    eq(attempts, 2, "busy upload retried")
    eq(uploaded.percent, 25, "retry uses immutable position")
    eq(f.values.books.book.pending_upload_position, nil,
        "retry success clears pending snapshot")
end)

test("suspend parks movement locally without starting network work", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    eq(#f.uploads, 0, "suspend does not start network work")
    eq(f.values.books.book.pending_upload_position.percent, 40, "suspend saves current page")
    eq(f.values.books.book.pending_upload_account, f.sync:_account_key(), "suspend binds pending location to account")
end)

test("single chapter cloud choice waits for target chapter then jumps", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    local current_chapter = chapters[1]
    local requested_chapter
    f.sync.get_file_context = function()
        return 1, current_chapter, false
    end
    f.sync.open_chapter = function(_book, chapter)
        requested_chapter = chapter
        return true
    end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "chapter conflict requested")
    f.choices[1].use_remote()
    eq(requested_chapter.chapterUid, 22, "target chapter requested")
    eq(f.sync:status().verified, false, "reporting remains gated")
    eq(f.sync:status().state, "switching_chapter", "waiting for open")

    -- Simulate the downloader opening the requested single-chapter EPUB.
    current_chapter = chapters[2]
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "target chapter verifies")
    eq(f.jumps[#f.jumps], 0.5, "target chapter offset applied")
end)

test("cancelling target chapter download clears the pending jump", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync.get_file_context = function()
        return 1, chapters[1], false
    end
    f.sync.open_chapter = function() return true end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    eq(f.sync:cancel_pending_jump("cancelled"), true, "pending cancelled")
    eq(f.sync:status().state, "unverified", "returns to safe state")
    eq(f.sync:status().verified, false, "reporting stays gated")
end)

test("automatic hooks stay disabled when flags are absent", function()
    local f = fixture({
        bookId = "book",
        progress = 75,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 300,
        updateTime = 10,
    })
    f.values.sync = {}
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().state, "unverified", "open does not pull by default")
    eq(#f.choices, 0, "open does not prompt by default")

    f.sync.verified = true
    f.sync.dirty = true
    f.sync:on_close_document()
    eq(#f.uploads, 0, "close does not upload by default")
end)

test("manual sync refreshes a missing catalog inside the online task", function()
    local available_chapters
    local refresh_count = 0
    local online_count = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        get_chapters = function() return available_chapters end,
        refresh_catalog = function(book_id)
            eq(book_id, "book", "refresh receives current book")
            refresh_count = refresh_count + 1
            available_chapters = chapters
            return chapters
        end,
        run_online = function(_kind, callback)
            online_count = online_count + 1
            callback()
            return true
        end,
    })
    eq(f.sync:sync_now(), true, "manual sync starts")
    eq(refresh_count, 1, "catalog refreshed once")
    eq(online_count, 1, "catalog and progress share one online task")
    eq(f.sync:status().verified, true, "refreshed catalog completes sync")
    eq(#f.notifications, 1, "aligned manual sync notifies once")
    eq(f.notifications[1].code, "already_synced", "sync result notified")
end)

test("automatic open never refreshes a missing catalog", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(refresh_count, 0, "automatic path stays offline")
    eq(f.sync:status().state, "unsafe", "missing catalog degrades safely")
end)

test("offline manual catalog refresh reports offline instead of raw reason", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline sync does not start")
    eq(refresh_count, 0, "offline path does not refresh")
    eq(#f.notifications, 1, "offline failure notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("offline automatic pull schedules a delayed retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    -- Wi-Fi is usually still settling when the open delay expires.
    f.step()
    eq(f.sync:status().state, "offline", "automatic pull records offline")
    eq(#f.queue, 1, "offline automatic pull queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry waits for the link")
    eq(#f.notifications, 0, "automatic retry stays silent")
end)

test("automatic pull retries stop at the attempt limit", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "first retry queued")
    f.step()
    eq(#f.queue, 1, "second retry queued")
    f.step()
    eq(#f.queue, 1, "third retry queued")
    f.step()
    eq(#f.queue, 0, "retries stop at the limit")
    eq(f.sync:status().verified, false, "exhausted retries stay gated")
end)

test("offline manual sync never schedules a retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline manual sync does not start")
    eq(#f.queue, 0, "manual path leaves the queue empty")
    eq(#f.notifications, 1, "manual offline notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("retries queued for a closed book never pull again", function()
    local online_checks = 0
    local f = fixture({}, {
        is_online = function()
            online_checks = online_checks + 1
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "retry queued for the open book")
    f.sync:on_close_document()
    f.step()
    eq(online_checks, 1, "stale retry never reaches the offline check")
    eq(#f.queue, 0, "stale retry does not queue another attempt")
end)

test("a queued retry verifies once the link comes back", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().verified, false, "offline open leaves the gate closed")
    online = true
    f.drain()
    eq(f.sync:status().verified, true, "retry verifies the reporting gate")
    eq(#f.choices, 0, "no conflict dialog")
    eq(#f.notifications, 0, "automatic retry stays silent")
    local position, reason = f.sync:position_for_report("book")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
end)

test("automatic pull retries when the online task cannot start", function()
    local run_options
    local f = fixture({}, {
        is_online = function() return true end,
        run_online = function(_kind, _callback, options)
            run_options = options
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().state, "offline", "failed online task records offline")
    eq(#f.queue, 1, "failed automatic online task queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry remains delayed")
    eq(run_options.silent_offline, true, "automatic preflight stays silent")
    eq(#f.notifications, 0, "automatic start failure does not notify")
end)

test("queued automatic retry does not duplicate a manual conflict", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 80,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 500,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    online = true
    f.sync:sync_now()
    eq(#f.choices, 1, "manual sync opens one conflict")
    f.step()
    eq(#f.choices, 1, "stale automatic retry does not reopen conflict")
    eq(#f.queue, 0, "stale retry chain ends")
end)

test("a fresh automatic pull replaces an older retry chain", function()
    local now = 0
    local f = fixture({}, {
        is_online = function() return false end,
        now = function() return now end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "open queues the first retry chain")
    f.sync:on_suspend()
    now = 5 * 60
    f.sync:on_resume()
    eq(#f.queue, 2, "resume queues its replacement chain")
    f.step()
    eq(#f.queue, 1, "stale chain does not schedule another retry")
    f.step()
    eq(#f.queue, 1, "replacement chain remains active")
end)

test("closed session discards queued pulls before network work", function()
    local callbacks, requests = {}, 0
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback
        return true
    end })
    f.client.get_progress = function() requests = requests + 1 return {} end
    f.client.get_web_progress = f.client.get_progress
    f.sync:on_reader_ready()
    f.drain()
    f.sync:on_close_document()
    callbacks[1]()
    eq(requests, 0, "closed pull never sends a request")
    eq(f.sync.pulling, false, "close releases pull ownership")
end)

test("old pull cannot clear a replacement session's pull", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback
        return true
    end })
    f.sync:on_reader_ready()
    f.drain()
    f.sync:on_reader_ready()
    f.drain()
    eq(#callbacks, 2, "reopen starts a fresh pull")
    callbacks[1]()
    eq(f.sync.pulling, true, "stale completion preserves new pull ownership")
    if callbacks[2] then callbacks[2]() end
    eq(f.sync.pulling, false, "current pull completes")
end)

test("account switch cancels queued uploads and busy retries", function()
    for _, busy in ipairs({ false, true }) do
        local callbacks, attempts = {}, 0
        local f = fixture({}, { run_online = function(_kind, callback)
            callbacks[#callbacks + 1] = callback
            return true
        end })
        f.sync.upload_position = function()
            attempts = attempts + 1
            return not busy, { error_kind = "busy" }
        end
        local position = assert(f.sync:capture_local())
        f.sync:_upload_snapshot(position, "manual_sync", true)
        if busy then callbacks[1]() end
        f.values.account.user_vid = "fixture-account-b"
        if busy then f.drain() else callbacks[1]() end
        eq(attempts, busy and 1 or 0, "stale account never dispatches another upload")
        eq(f.sync.uploading, false, "stale account releases upload ownership")
        eq(#f.notifications, 0, "stale account shows no completion notification")
        eq(f.values.books.book.last_uploaded_position, nil, "stale account receives no acknowledgement")
    end
end)

test("old remote-jump refresh cannot persist another book's location", function()
    local f = fixture({ bookId = "book", progress = 50, chapterUid = 33, chapterOffset = 100 })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    local before = f.values.books.book.last_local_position
    f.sync.detect_book = function() return "other" end
    f.document.file = "/cache/other.epub"
    f.drain()
    eq(f.values.books.book.last_local_position, before, "late jump refresh leaves old book untouched")
end)

test("upload acknowledgement preserves newer movement and pending snapshot", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback
        return true
    end })
    f.sync.verified = true
    local first = assert(f.sync:capture_local())
    f.sync:_upload_snapshot(first, "manual_sync", true)
    f.document.page = 75
    local latest = assert(f.sync:capture_local())
    f.sync.local_position = latest
    f.sync.dirty = true
    f.sync:_upload_snapshot(latest, "document_close", false)
    callbacks[1]()
    eq((f.values.books.book.pending_upload_position or {}).percent, 75, "acknowledgement retains newer pending location")
    eq((f.values.books.book.last_local_position or {}).percent, 75, "acknowledgement does not rewind local state")
    eq(f.sync.dirty, true, "movement after dispatch remains dirty")
end)

test("close upload survives document teardown without changing the next session", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback
        return true
    end })
    f.sync.verified, f.sync.dirty = true, true
    f.sync:on_close_document()
    f.sync.detect_book = function() return "other" end
    f.document.file = "/cache/other.epub"
    f.sync:on_reader_ready()
    f.sync.state, f.sync.dirty = "waiting", true
    callbacks[1]()
    eq(#f.uploads, 1, "same-account close upload completes")
    eq(f.uploads[1].book_id, "book", "close keeps original book identity")
    eq(f.sync.state, "waiting", "old acknowledgement preserves next session state")
    eq(f.sync.dirty, true, "old acknowledgement preserves next session movement")
end)

test("queued pull compares the live page and local choice captures current movement", function()
    local callbacks = {}
    local f = fixture({ bookId = "book", progress = 50, chapterUid = 33, chapterOffset = 100 }, {
        run_online = function(_kind, callback) callbacks[#callbacks + 1] = callback return true end,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 50
    callbacks[1]()
    eq(#f.choices, 0, "page changed while queued already matches cloud")
    f.document.page = 25
    f.sync:sync_now()
    callbacks[2]()
    f.document.page = 75
    f.choices[1].keep_local()
    callbacks[3]()
    eq(f.uploads[1].percent, 75, "keep local uses latest local page")
    f.choices[1].keep_local()
    eq(#callbacks, 3, "conflict decision only executes once")
end)

test("account transition revokes decisions and pending cross-chapter jumps", function()
    local f = fixture({ bookId = "book", progress = 50, chapterUid = 33, chapterOffset = 100 })
    f.sync:on_reader_ready()
    f.drain()
    local choice = f.choices[1]
    f.sync:on_account_changed()
    choice.keep_local()
    choice.use_remote()
    eq(#f.uploads, 0, "old decision cannot upload after reauthentication")
    eq(#f.jumps, 0, "old decision cannot navigate after reauthentication")
    eq(f.sync.verified, false, "new account starts with an unverified reader")
    f.sync.pending_jump = { book_id = "book", account_generation = 0, account = "old-account", chapter_uid = 22 }
    eq(f.sync:_apply_pending_jump("book"), false, "old account's chapter jump is discarded")
    eq(f.sync.pending_jump, nil, "old chapter intent removed")
end)

test("account changes during the first source prevent the second source request", function()
    local f = fixture({})
    local web_calls = 0
    f.client.get_progress = function()
        f.values.account.user_vid = "fixture-account-b"
        return {}
    end
    f.client.get_web_progress = function() web_calls = web_calls + 1 return {} end
    f.sync:on_reader_ready()
    f.drain()
    eq(web_calls, 0, "second source never uses replacement account credentials")
    eq(f.values.books.book.last_remote_position, nil, "mixed-account source result not persisted")
end)

test("selecting cloud cancels queued local writes", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback return true
    end })
    local local_position, _, context = f.sync:capture_local()
    f.sync:_upload_snapshot(local_position, "manual_sync", true)
    assert(f.sync:_apply_remote({ percent = 50, chapter_uid = 33, chapter_offset = 100 }, context))
    callbacks[1]()
    eq(#f.uploads, 0, "cloud selection cancels queued local upload")
    eq(f.values.books.book.pending_upload_position, nil, "superseded local intent removed")
    eq(f.sync.uploading, false, "superseded upload ownership released")
end)

test("source cloud navigation defers old intent and never grants report permission", function()
    local callbacks={}
    local f=fixture({}, {run_online=function(_kind,callback) callbacks[#callbacks+1]=callback;return true end})
    local local_position=f.sync:capture_local()
    f.sync:_mark_verified('book','fixture',local_position,{})
    f.sync:_upload_snapshot(local_position,'before_source_cloud',false)
    f.sync:begin_cloud_source_navigation()
    callbacks[1]()
    eq(#f.uploads,0,'source choice cancels unsent local request')
    eq(f.sync.verified,false,'source choice blocks automatic reporting')
    eq(f.values.books.book.pending_upload_position.percent,local_position.percent,'failed or cancelled lookup retains durable local intent')
    local held={book_id='book',chapter_uid='22',chapter_offset=15,file_id=string.rep('a',64),book_version=7,
        raw_sha256=string.rep('b',64),render_path='chapter.xhtml',basis='filtered_xhtml_utf16',upload_verified=false}
    f.sync.current_source_target=function() return held end
    local wrong={};for key,value in pairs(held) do wrong[key]=value end;wrong.chapter_offset=16
    eq(f.sync:accept_cloud_source_target(wrong),false,'foreign source target cannot discard local intent')
    eq(f.sync:accept_cloud_source_target(held),true,'applied held cloud target supersedes local intent')
    eq(f.values.books.book.pending_upload_position,nil,'successful source choice discards old local intent')
    eq(f.sync.verified,false,'read target cannot grant wire verification')
    local provided,reason=f.sync:position_for_report('book')
    eq(provided,nil,'unverified precise target cannot report')
    eq(reason,'progress_unverified','precise target keeps the report gate closed')
    local other=fixture({})
    local foreign={book_id='other-book'};other.sync.upload_job,other.sync.uploading=foreign,true
    other.sync:begin_cloud_source_navigation()
    eq(other.sync.upload_job,foreign,'source choice does not cancel a different book upload')
    eq(other.sync.uploading,true,'other book keeps upload ownership')
end)

test("suspend invalidates queued pulls and short resume retries unverified session", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback return true
    end })
    local requests = 0
    f.client.get_progress = function() requests = requests + 1 return {} end
    f.sync:on_reader_ready()
    f.drain()
    f.sync:on_suspend()
    callbacks[1]()
    eq(requests, 0, "suspend cancels queued reads")
    f.sync:on_resume()
    eq(#callbacks, 2, "short resume retries a cancelled unverified pull")
end)

test("wake does not replay a queued pre-suspend upload ahead of cloud recheck", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback return true
    end })
    f.sync.verified, f.sync.dirty = true, true
    local position = assert(f.sync:capture_local())
    f.sync:_upload_snapshot(position, "manual_sync", false)
    f.sync:on_suspend()
    f.sync:on_resume()
    callbacks[1]()
    eq(#f.uploads, 0, "pre-suspend upload remains cancelled after wake")
    eq(f.sync.verified, false, "time reporting waits for cloud comparison")
    eq(f.sync.pulling, true, "wake starts a fresh cloud comparison")
    eq(f.values.books.book.pending_upload_position.percent, position.percent, "wake retains unsent local intent")
end)

test("reopening the same book cancels its previous session's queued close upload", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback return true
    end })
    f.sync.verified, f.sync.dirty = true, true
    f.sync:on_close_document()
    f.sync:on_reader_ready()
    callbacks[1]()
    eq(#f.uploads, 0, "reopened book supersedes old close upload")
    eq(f.sync.uploading, false, "old close upload no longer blocks current session")
end)

test("a matching cloud read discards superseded pending intent", function()
    local f = fixture({ bookId = "book", progress = 25, chapterUid = 22, chapterOffset = 150 })
    f.values.books.book.pending_upload_position = { book_id = "book", percent = 10 }
    f.values.books.book.pending_upload_account = f.sync:_account_key()
    f.sync:on_reader_ready()
    f.drain()
    eq(f.values.books.book.pending_upload_position, nil, "aligned current location replaces old unsent intent")
    eq(f.sync.verified, true, "matching cloud location still verifies reporting")
end)

test("capture uses the live document before footer refresh", function()
    local mode = "page"
    local f = fixture({}, {
        get_footer = function() return { percent_finished = 0.99 } end,
        get_view_mode = function() return mode end,
    })
    f.document.page = 31
    local position = assert(f.sync:capture_local())
    eq(position.percent, 31, "stale footer cannot overwrite current page")
    f.document.getCurrentPos = function() return 23345 end
    f.document.info = { doc_height = 100000 }
    mode = "scroll"
    position = assert(f.sync:capture_local())
    eq(position.percent, 23, "scroll capture uses engine position instead of page percentage")
    eq(position.fraction, 0.23345, "scroll capture preserves fractional precision")
end)

test("late jump refresh preserves a subsequent page turn", function()
    local f = fixture({ bookId = "book", progress = 50, chapterUid = 33, chapterOffset = 100 })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    f.document.page = 75
    f.sync:on_page_update()
    f.drain()
    eq(f.sync.dirty, true, "jump refresh does not acknowledge a later page turn")
    eq(f.sync.local_position.percent, 75, "jump refresh keeps the actual current page")
end)

test("local source coordinates remain separate from the existing wire units", function()
    local source = { book_id = "book", chapter_uid = "22", chapter_offset = 12345,
        file_id = string.rep("a", 64), basis = "filtered_xhtml_utf16", upload_verified = false }
    local f = fixture({ chapterUid = 22, chapterOffset = 10, progress = 25 }, {
        get_source_position = function() return source end,
    })
    local before = assert(f.sync:capture_local())
    eq(before.chapter_offset == source.chapter_offset, false, "source offset did not replace wire units")
    eq(before.source_position.chapter_offset, 12345, "read-only local source snapshot included")
    before.source_position.chapter_offset = -1
    eq(source.chapter_offset, 12345, "capture copied source snapshot")
    eq(f.sync:status().source_position.basis, "filtered_xhtml_utf16", "status exposes precise local basis")
    f.sync.current_book_id = "book"
    f.sync.local_position = assert(f.sync:capture_local())
    f.sync.dirty = false
    f.sync:on_source_position_changed("ready", source)
    eq(f.sync.source_state, "ready", "source readiness delivered")
    eq(f.sync.dirty, false, "preparation did not create upload intent")
    f.sync:on_source_position_changed("waiting", nil)
    eq(f.sync.local_position.source_position, nil, "page invalidation cleared source snapshot")
end)

test("selected cloud target survives page rounding until actual navigation", function()
    local f = fixture({})
    local before, _, context = f.sync:capture_local()
    f.sync.local_position = before
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_idx = 2,
        chapter_offset = 154, percent = 25.4, has_chapter_offset = true }, context))
    eq(f.document.page, 25, "target is on the current native page")
    local retained = assert(f.sync:capture_local())
    eq(retained.chapter_offset, 154, "page origin did not replace selected target")
    eq(retained.viewport_fraction, 0.25, "actual viewport remains distinguishable from retained target")
    eq(retained.retained_remote_target, true, "retained target is explicit")
    f.sync:on_page_update()
    f.drain()
    eq(f.sync.local_position.chapter_offset, 154, "redraw and delayed capture retained target")
    eq(f.sync.dirty, false, "redraw did not create upload intent")
    eq(assert(f.sync:position_for_report("book")).chapter_offset, 154, "report uses selected target")
    f.document.page = 26
    f.sync:on_page_update()
    eq(f.sync.local_position.chapter_offset, 160, "real navigation resumes live capture")
    eq(f.sync.dirty, true, "real movement is uploadable under existing gate")
    f.document.page = 25
    f.sync:on_page_update()
    eq(f.sync.local_position.chapter_offset, 150, "returning to the page cannot revive an old target")
end)

test("retention preserves exact offsets and the selected chapter at a boundary", function()
    local f = fixture({}, { get_chapters = function()
        return { { chapterUid = 11, chapterIdx = 1, wordCount = 101 },
            { chapterUid = 22, chapterIdx = 2, wordCount = 301 },
            { chapterUid = 33, chapterIdx = 3, wordCount = 5 } }
    end })
    local before, _, context = f.sync:capture_local()
    f.sync.local_position = before
    for _, offset in ipairs({ 4, 9, 14, 19, 301 }) do
        assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = offset, percent = 25 }, context))
        local retained = assert(f.sync:capture_local())
        eq(retained.chapter_uid, 22, "retained source chapter is not inferred from percentage")
        eq(retained.chapter_offset, offset, "known offset does not make a floating-point round trip")
    end
end)

test("reflow retains a visible target but subsequent navigation never revives it", function()
    local mode, layout, xp, visible, at = "page", 1, "original", true, 123
    local f = fixture({}, { get_view_mode = function() return mode end })
    f.document.getXPointer = function() return xp end
    f.document.getDocumentRenderingHash = function() return layout end
    f.document.getCurrentPos = function() return at end
    f.document.getPosFromXPointer = function() return at end
    f.document.info = { doc_height = 10000 }
    f.document.isXPointerInCurrentPage = function() return visible end
    local before, _, context = f.sync:capture_local()
    f.sync.local_position = before
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    layout, xp, f.document.page, at = 2, "reflowed", 30, 200
    f.sync:on_page_update()
    eq(f.sync.local_position.chapter_offset, 154, "visible native anchor survives reflow")
    eq(f.sync.dirty, false, "reflow is not reading movement")
    mode = "scroll"
    f.sync:on_page_update()
    eq(f.sync.local_position.chapter_offset, 154, "mode switch preserved the same native anchor")
    at = at + 1
    f.sync:on_page_update()
    eq(f.sync.local_position.retained_remote_target, nil, "real scroll invalidates target even while anchor is visible")
    mode, layout, xp, f.document.page, at = "page", 1, "original", 25, 123
    f.sync:on_page_update()
    eq(f.sync.local_position.chapter_offset, 150, "return to original layout does not revive target")

    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    layout, xp, f.document.page, visible = 3, "unrelated", 40, false
    eq(assert(f.sync:capture_local()).retained_remote_target, nil, "reflow without visible anchor is not accepted")
    eq(f.sync.verified, false, "unverified layout cannot report a guessed page-origin position")
    f.sync:on_close_document()
    f.drain()
    eq(#f.uploads, 0, "unverified reflow cannot cause a reverse close upload")
end)

test("retained target is bound to document and account and survives short suspend", function()
    local f = fixture({})
    local before, _, context = f.sync:capture_local()
    f.sync.local_position = before
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    f.sync:on_suspend()
    f.sync:on_resume()
    eq(assert(f.sync:capture_local()).chapter_offset, 154, "short suspend without movement retains target")
    f.values.account.user_vid = "fixture-other-owner"
    eq(assert(f.sync:capture_local()).chapter_offset, 150, "changed account cannot retain old target")
    f.values.account.user_vid = "fixture-account-a"
    eq(assert(f.sync:capture_local()).retained_remote_target, nil, "restored account cannot revive target")
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    local replacement = {}
    for key, value in pairs(f.document) do replacement[key] = value end
    f.sync.get_document = function() return replacement end
    eq(assert(f.sync:capture_local()).retained_remote_target, nil, "same-path document replacement invalidates target")
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync.remote_anchor, nil, "reader ready never inherits a prior target")
end)

test("layout settles once and an explicit native navigation marker cancels retention", function()
    local layout, xp, marker, at = 1, "original", "original", 0
    local f = fixture({}, {
        get_navigation_xpointer = function() return marker end,
        get_viewport_height = function() return 800 end,
    })
    f.document.getXPointer = function() return xp end
    f.document.getDocumentRenderingHash = function() return layout end
    f.document.getCurrentPos = function() return at end
    f.document.isXPointerInCurrentPage = function() return true end
    local before, _, context = f.sync:capture_local()
    f.sync.local_position = before
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    f.drain()
    layout, xp, at, f.document.page = 2, "intermediate", 50, 30
    f.sync:on_page_update()
    xp, at = "settled", 60
    f.sync:on_page_update()
    eq(f.sync.local_position.chapter_offset, 154, "intermediate layout frame did not become reading movement")
    eq(#f.queue, 1, "layout rebasing is coalesced")
    f.step()
    xp, at = "native-position-restored-on-draw", 70
    eq(assert(f.sync:capture_local()).chapter_offset, 154, "post-draw native restoration retained target")
    f.drain()
    eq(f.sync.local_position.chapter_offset, 154, "settled layout retained target")
    eq(f.sync.dirty, false, "intermediate frames did not mark progress dirty")
    marker = "a-new-target-in-the-same-native-page"
    eq(assert(f.sync:capture_local()).retained_remote_target, nil, "same-page explicit jump cancels old target")

    marker = "original"
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    f.drain()
    layout, at = 3, 80
    f.sync:on_page_update()
    marker = "new-user-navigation-during-layout"
    eq(assert(f.sync:capture_local()).retained_remote_target, nil, "user navigation during reflow cancels retention")
    f.drain()
    eq(f.sync.remote_anchor, nil, "late layout task cannot revive superseded anchor")

    marker = "original"
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    f.drain()
    layout, at = 4, 100
    f.sync:on_page_update()
    f.sync:on_suspend()
    f.drain()
    eq(f.sync.remote_anchor.reflow_pending, nil, "suspend stops layout sampling")
    f.sync:on_resume()
    eq(assert(f.sync:capture_local()).chapter_offset, 154, "resume can finish an interrupted layout")
    f.drain()
    layout = 5
    f.sync:on_page_update()
    for index = 1, 4 do
        xp, at = "changing-" .. index, 100 + index * 10
        f.step()
    end
    eq(f.sync.remote_anchor, nil, "never-stable layout has a bounded retry count")
    eq(#f.queue, 0, "bounded layout work leaves no polling loop")
    eq(f.sync.verified, false, "unstable layout requires position verification before reports")
end)

test("closing an unchanged selected cloud target does not upload its page origin", function()
    local f = fixture({})
    local before, _, context = f.sync:capture_local()
    f.sync.local_position = before
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    f.sync:on_close_document()
    f.drain()
    eq(#f.uploads, 0, "cloud selection without reading movement does not write back")
    eq(f.values.books.book.last_local_position.chapter_offset, 154, "persisted selection remains exact")
    eq(f.sync.remote_anchor, nil, "close releases retained native anchor")
end)

test("chapter-file transitions retain their original offset after opening the target", function()
    local catalog = { { chapterUid = 11, chapterIdx = 1, wordCount = 101 },
        { chapterUid = 22, chapterIdx = 2, wordCount = 301 } }
    local current = catalog[1]
    local f = fixture({}, { get_chapters = function() return catalog end })
    f.sync.get_file_context = function() return 1, current, false end
    local before, _, context = f.sync:capture_local()
    f.sync.local_position = before
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 4, percent = 25 }, context))
    eq(f.sync.pending_jump.chapter_offset, 4, "pending chapter stores exact selected offset")
    current = catalog[2]
    f.document.file = "/cache/book/chapter-two.epub"
    f.sync:on_reader_ready()
    f.drain()
    eq(assert(f.sync:capture_local()).chapter_offset, 4, "new chapter reader retained target offset")
    eq(f.sync.local_position.retained_remote_target, true, "new chapter reader uses retained position")
end)

test("new local navigation revokes queued cloud reads and conflict choices", function()
    local queued = {}
    local f = fixture({ progress = 50, chapterUid = 33, chapterOffset = 100 }, {
        run_online = function(_kind, callback) queued[#queued + 1] = callback;return true end,
    })
    local reads = 0
    f.client.get_progress = function() reads = reads + 1;return {} end
    f.sync:on_reader_ready();f.drain()
    f.sync:begin_local_navigation()
    queued[1]()
    eq(reads, 0, "queued read cannot start after a newer local request")
    eq(f.sync.verified, false, "local request does not grant upload rights")

    local conflict = fixture({ progress = 50, chapterUid = 33, chapterOffset = 100 })
    conflict.sync:on_reader_ready();conflict.drain()
    local choice = conflict.choices[1]
    conflict.sync:begin_local_navigation()
    choice.use_remote();choice.keep_local()
    eq(#conflict.jumps, 0, "superseded conflict choice cannot navigate")
    eq(#conflict.uploads, 0, "superseded conflict choice cannot write")
end)

test("an early local request supersedes the delayed open comparison", function()
    local f = fixture({ progress = 50, chapterUid = 33, chapterOffset = 100 })
    local reads = 0
    f.client.get_progress = function() reads = reads + 1;return {} end
    f.sync:on_reader_ready()
    f.sync:begin_local_navigation()
    f.drain()
    eq(reads, 0, "old open timer cannot start a new cloud pull")
    eq(f.sync.current_book_id, "book", "reader bookkeeping still initialized")
    eq(f.sync.verified, false, "early request preserves verification gate")
end)

test("chapter handoff reaches a new controller once and recomputes file geometry", function()
    local catalog = { { chapterUid = 11, chapterIdx = 1, wordCount = 101 },
        { chapterUid = 22, chapterIdx = 2, wordCount = 301 } }
    local sender = fixture({}, { get_chapters = function() return catalog end })
    sender.sync.get_file_context = function() return 1, catalog[1], false end
    local before, _, context = sender.sync:capture_local();sender.sync.local_position = before
    assert(sender.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 4, percent = 25 }, context))
    local handoff = assert(sender.sync:chapter_handoff("/cache/book/chapter-two.epub"))
    sender.sync:on_close_document()
    local receiver = fixture({}, { get_chapters = function() return catalog end })
    receiver.document.file = "/cache/book/chapter-two.epub"
    receiver.sync.get_file_context = function() return 2, catalog[2], false end
    receiver.sync:on_reader_ready()
    local reader = { document = receiver.document, weread = { progress_sync = receiver.sync } }
    eq(handoff(reader), true, "new reader accepts one explicit handoff")
    eq(handoff(reader), false, "handoff cannot replay")
    receiver.drain()
    eq(receiver.sync.local_position.chapter_uid, 22, "receiver kept target chapter")
    eq(receiver.sync.local_position.chapter_offset, 4, "receiver kept exact offset")
    eq(receiver.sync.verified, true, "receiver applies selected target")
    eq(sender.sync.pending_jump, nil, "sender releases transferred intent")

    local full_sender = fixture({}, { get_chapters = function() return catalog end })
    full_sender.sync.get_file_context = function() return 1, catalog[1], false end
    local _, _, full_context = full_sender.sync:capture_local()
    assert(full_sender.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25 }, full_context))
    local full_handoff = assert(full_sender.sync:chapter_handoff("/cache/book/full.epub"))
    full_sender.sync:on_close_document()
    local full = fixture({}, { get_chapters = function() return catalog end })
    full.sync:on_reader_ready()
    assert(full_handoff({ document = full.document, weread = { progress_sync = full.sync } }))
    full.drain()
    eq(full.sync.local_position.chapter_offset, 154, "combined file retains selected chapter offset")
    eq(full.jumps[1], 255/402, "combined file uses overall fraction instead of old chapter-file fraction")
end)

test("chapter handoff rejects replacement accounts, paths and newer requests", function()
    for _, mode in ipairs({ "account", "path", "new_request" }) do
        local sender = fixture({})
        sender.sync.get_file_context = function() return 1, chapters[1], false end
        local _, _, context = sender.sync:capture_local()
        assert(sender.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
        local handoff = assert(sender.sync:chapter_handoff("/cache/book/chapter-two.epub"))
        if mode == "new_request" then sender.sync:begin_local_navigation() end
        sender.sync:on_close_document()
        local receiver = fixture({})
        receiver.document.file = mode == "path" and "/different.epub" or "/cache/book/chapter-two.epub"
        if mode == "account" then receiver.values.account.user_vid = "different-owner" end
        receiver.sync:on_reader_ready()
        eq(handoff({ document = receiver.document, weread = { progress_sync = receiver.sync } }), false,
            "handoff rejected " .. mode)
        eq(receiver.sync.pending_jump, nil, "foreign intent not installed")
    end
end)

for _i,format in ipairs({'web_xhtml','web_txt'}) do
test("native source targets remain file bound and separate from legacy progress: "..format, function()
    local Source = require("weread.lib.position_source")
    local Identity = require("weread.lib.book_file_identity")
    local Crypto = require("weread.lib.crypto")
    local native_point = "/body/DocFragment/body/p/text().12"
    local marker = native_point
    local f
    f = fixture({}, {
        get_navigation_xpointer = function() return marker end,
        get_source_position = function() return f and f.sync:current_source_target() end,
    })
    local book = { book_id = "book", bookVersion = 7 }
    local chapter = { chapterUid = 22 }
    local raw = "<html><body><p>Unique synthetic chapter for native source target binding.</p></body></html>"
    if format=='web_txt' then raw='Literal <tag>&amp; 😀 unique original TXT source for local position binding.' end
    local original = assert(Source.capture(book, chapter, raw, format))
    local root = Identity.encode(book, {chapter}, Identity.capture(book), Crypto.sha256_hex(raw))
    local identity = assert(Identity.decode(root))
    local path = "OEBPS/text/chapter.xhtml"
    local metadata = assert(Source.bind(original, identity, path, Crypto.sha256_hex(raw)))
    f.document.getDocumentFileContent = function(_self, name)
        if name == Identity.PATH then return root end
        if name == Source.meta_path(22) or name == Source.path_meta_path(path) then return metadata end
        error("source target binding read a body member")
    end
    f.document.getHTMLFromXPointers = function() return '<DocFragment Source="' .. path .. '"><body/>' end
    f.document.getNormalizedXPointer = function(_self, xp) return xp end
    f.document.getXPointer = function() return "viewport" end
    f.document.isXPointerInCurrentPage = function() return true end
    local position = { book_id = "book", chapter_uid = "22", chapter_offset = 32, file_id = identity.file_id,
        book_version = 7, raw_sha256 = original.raw_sha256, render_path = path,
        basis = Source.coordinate_basis(format), upload_verified = false, raw = "BODY_CANARY" }
    local wrong_basis={};for key,value in pairs(position) do wrong_basis[key]=value end
    wrong_basis.basis=format=='web_txt' and 'filtered_xhtml_utf16' or 'raw_txt_utf16'
    eq(f.sync:retain_source_target(wrong_basis,native_point,metadata),false,'source format and coordinate basis must match')
    eq(f.sync:retain_source_target(position, native_point, metadata), true, "verified visible source target retained")
    local held = assert(f.sync:current_source_target())
    eq(held.retained_source_target, true, "source retention is explicit")
    eq(held.raw, nil, "binding retained only approved metadata")
    eq(held.basis, Source.coordinate_basis(format), 'retained source basis changed')
    if format=='web_txt' then
        eq(f.sync:accept_cloud_source_target(position),false,'TXT local target acquired cloud interpretation')
        eq(f.sync:accept_cloud_source_target(wrong_basis),false,'XHTML target matched a retained TXT position')
    end
    held.chapter_offset = 999
    eq(f.sync:current_source_target().chapter_offset, 32, "returned source target is a copy")
    local captured = assert(f.sync:capture_local())
    eq(captured.chapter_offset, 150, "source target did not replace legacy wire units")
    eq(captured.source_position.chapter_offset, 32, "source target exposed independently")
    eq(f.sync.verified, false, "local source jump did not grant cloud upload rights")
    local _, _, context = f.sync:capture_local()
    local cancelled = 0
    f.sync.on_before_navigate = function() cancelled = cancelled + 1 end
    assert(f.sync:_apply_remote({ chapter_uid = 22, chapter_offset = 154, percent = 25.4 }, context))
    eq(cancelled, 1, "cloud application cancels any pending local source navigation first")
    eq(f.sync:current_source_target(), nil, "new cloud choice clears an old source target even on the same native page")
    assert(f.sync:retain_source_target(position, native_point, metadata))
    marker = "new-point-in-the-same-page"
    eq(f.sync:current_source_target(), nil, "new native marker invalidates source target")
    position.file_id = string.rep("a", 64)
    eq(f.sync:retain_source_target(position, native_point, metadata), false, "foreign file target rejected")
end)
end

test("close keeps the final ready source snapshot after the source service stops", function()
    local source = { book_id = "book", chapter_uid = "22", chapter_offset = 12345,
        file_id = string.rep("a", 64), basis = "filtered_xhtml_utf16", upload_verified = false }
    local f = fixture({}, { get_source_position = function() return nil end })
    local legacy = assert(f.sync:capture_local())
    f.sync.verified, f.sync.dirty = true, true
    f.sync:on_close_document(source)
    source.chapter_offset = 999
    f.drain()
    eq(#f.uploads, 1, "existing close upload still executes")
    eq(f.uploads[1].chapter_offset, legacy.chapter_offset, "close retained wire units")
    eq(f.uploads[1].source_position.chapter_offset, 12345, "close copied final source snapshot")
    eq(f.sync:status().source_position, nil, "closed service exposes no live position")

    local disabled = fixture({})
    disabled.sync.verified, disabled.sync.dirty = true, true
    disabled.values.sync.upload_on_close = false
    disabled.sync:on_close_document(source)
    disabled.drain()
    eq(#disabled.uploads, 0, "source readiness cannot enable disabled uploads")
end)

test("suspend retains a copied source snapshot only for the same book", function()
    local source = { book_id = "book", chapter_uid = "22", chapter_offset = 12345 }
    local f = fixture({})
    f.sync.local_position = assert(f.sync:capture_local())
    f.sync.verified, f.sync.dirty = true, true
    local legacy_offset = f.sync.local_position.chapter_offset
    f.sync:on_suspend(source)
    source.chapter_offset = 999
    local pending = f.values.books.book.pending_upload_position
    eq(pending.source_position.chapter_offset, 12345, "suspend copied ready source before cancellation")
    eq(pending.chapter_offset, legacy_offset, "suspend retained wire units")
    eq(#f.uploads, 0, "suspend only persists existing intent")

    local other = fixture({})
    other.sync.local_position = assert(other.sync:capture_local())
    other.sync.verified, other.sync.dirty = true, true
    other.sync:on_suspend({ book_id = "other", chapter_offset = 54321 })
    eq(other.values.books.book.pending_upload_position.source_position, nil, "other book source rejected")
    local unverified = fixture({})
    unverified.sync.dirty = true
    unverified.sync:on_suspend(source)
    eq(unverified.values.books.book.pending_upload_position, nil, "source cannot bypass verification gate")
end)

test("offline unverified close preserves the latest local reading intent", function()
    local f = fixture({}, { is_online = function() return false end })
    f.sync:on_reader_ready(); f.drain()
    f.document.page = 64; f.sync:on_page_update(); f.sync:on_close_document()
    local saved = f.values.books.book
    eq(saved.last_local_position.percent, 64, "offline close saves latest location")
    eq((saved.pending_upload_position or {}).percent, 64, "unverified movement remains available for later comparison")
    eq(saved.pending_upload_account, f.sync:_account_key(), "offline intent remains account-bound")
    eq(#f.uploads, 0, "local checkpoint does not grant upload permission")
end)

test("manual-only reading checkpoints without enabling automatic sync", function()
    local f = fixture({})
    f.values.sync.pull_on_open, f.values.sync.upload_on_close = false, false
    f.sync:on_reader_ready(); f.drain()
    f.document.page = 61; f.sync:on_page_update()
    f.sync:checkpoint_local("settings_flush")
    eq(f.values.books.book.pending_upload_position.percent, 61, "flush saves manual-only movement")
    eq(f.sync.verified, false, "local save cannot verify the cloud session")
    eq(f.sync:on_network_connected(), false, "manual-only settings prevent reconnect lookup")
    f.document.page = 73; f.sync:on_page_update(); f.sync:on_suspend()
    eq(f.values.books.book.pending_upload_position.percent, 73, "unverified sleep captures newer page")
    f.sync:on_resume()
    eq(#f.uploads, 0, "manual-only resume cannot replay checkpoint")
    eq(#f.choices, 0, "manual-only resume does not ask a cloud question")
    f.document.page = 82; f.sync:on_page_update(); f.sync:on_close_document()
    eq(f.values.books.book.pending_upload_position.percent, 82, "close replaces older local checkpoint")
end)

test("unchanged reading and replaced accounts cannot create a new local intent", function()
    local f = fixture({})
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready(); f.drain()
    f.sync:checkpoint_local("settings_flush")
    eq(f.values.books.book.pending_upload_position, nil, "opening alone is not unsent movement")
    f.document.page = 65; f.sync:on_page_update()
    f.values.account = { user_vid = "fixture-account-b" }
    eq(f.sync:checkpoint_local("settings_flush"), nil, "changed account rejects old document position")
    eq(f.values.books.book.pending_upload_position, nil, "new account did not inherit old movement")
    f.sync:on_account_changed()
    f.sync:on_close_document()
    eq(f.values.books.book.pending_upload_position, nil, "account-change close did not save old reader as new user")
end)

test("reconnect restarts an exhausted offline read chain before any upload", function()
    local online = false
    local f = fixture({ bookId = "book", progress = 25, chapterUid = 22, chapterOffset = 150 },
        { is_online = function() return online end })
    local reads = 0
    f.client.get_progress = function() reads = reads + 1; return { book = { bookId = "book", progress = 25 } } end
    f.sync:on_reader_ready(); f.drain()
    eq(reads, 0, "offline retries made no request")
    f.document.page = 65; f.sync:on_page_update(); f.sync:on_network_disconnected()
    eq(f.values.books.book.pending_upload_position.percent, 65, "disconnect parks the live page")
    online = true
    eq(f.sync:on_network_connected(), true, "link event starts a fresh read after retries exhausted")
    eq(reads, 1, "one gateway lookup on reconnect")
    eq(#f.uploads, 0, "reconnect cannot send before a position decision")
    eq(#f.choices, 1, "changed cloud position is compared with the live local page")
    eq(f.sync:on_network_connected(), false, "duplicate link event keeps current choice")
    eq(reads, 1, "duplicate event does not refetch cloud")
    f.choices[1].keep_local()
    eq(#f.uploads, 1, "explicit current local choice uploads once")
    eq(f.values.books.book.pending_upload_position, nil, "acknowledgement clears chosen checkpoint")
end)

test("network loss revokes queued writes and old conflict decisions", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback) callbacks[#callbacks + 1] = callback; return true end })
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready(); f.drain()
    f.sync.verified = true
    f.document.page = 54; f.sync:on_page_update()
    f.sync:_upload_snapshot(assert(f.sync:capture_local()), "manual_sync", false)
    f.sync:on_network_disconnected()
    callbacks[1]()
    eq(#f.uploads, 0, "lost link revoked the queued write")
    eq(f.sync.verified, false, "report gate closes on link loss")
    eq(f.values.books.book.pending_upload_position.percent, 54, "revoked write retains durable intent")
    f.sync:on_network_connected()
    eq(#callbacks, 1, "disabled automatic sync does not restart cloud work")

    local g = fixture({ bookId = "book", progress = 70 })
    g.sync:on_reader_ready(); g.drain()
    local old = g.choices[1]
    g.sync:on_network_disconnected()
    old.keep_local(); old.use_remote()
    eq(#g.uploads, 0, "old conflict decision cannot write after disconnect")
    eq(#g.jumps, 0, "old conflict decision cannot navigate after disconnect")
    g.sync:on_network_connected()
    eq(#g.choices, 2, "reconnect creates a current comparison")
end)

test("reconnect respects source navigation and session ownership", function()
    local f = fixture({})
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready(); f.drain()
    f.values.sync.pull_on_open = true
    f.sync.current_source_target = function() return { upload_verified = false } end
    eq(f.sync:on_network_connected(), false, "read-only source target is not replaced by reconnect")
    f.sync.current_source_target = function() return nil end
    f.values.account = { user_vid = "fixture-account-b" }
    eq(f.sync:on_network_connected(), false, "new credentials cannot compare the old reading session")
    eq(#f.choices, 0, "account mismatch did not create a decision")
end)

test("failed cloud navigation preserves the checkpoint while revoking its queued write", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback) callbacks[#callbacks + 1] = callback; return true end })
    local position, _, context = f.sync:capture_local()
    f.sync:_upload_snapshot(position, "manual_sync", false)
    f.sync.verified, f.sync.dirty = true, true
    f.sync.goto_fraction = function() return false, "engine_unavailable" end
    eq(f.sync:_apply_remote({ percent = 50, chapter_uid = 33, chapter_offset = 100 }, context), false,
        "native navigation failure is reported")
    eq((f.values.books.book.pending_upload_position or {}).percent, position.percent,
        "failed cloud jump retains the durable local location")
    eq(f.sync.verified, false, "failed jump cannot retain upload verification")
    f.sync:on_close_document()
    callbacks[1]()
    eq(#f.uploads, 0, "failed navigation cannot revive the old queued write")
end)

test("a cloud chapter switch discards local intent only after the new chapter is applied", function()
    for _, mode in ipairs({ "failed", "cancelled", "applied" }) do
        local f = fixture({ bookId = "book", progress = 25, chapterUid = 22, chapterIdx = 2, chapterOffset = 150 })
        local chapter = chapters[1]
        f.sync.get_file_context = function() return 1, chapter, false end
        f.sync.open_chapter = function() return mode ~= "failed", "download_failed" end
        f.sync:on_reader_ready(); f.drain()
        local position = assert(f.sync:capture_local())
        f.values.books.book.pending_upload_position = position
        f.values.books.book.pending_upload_account = f.sync:_account_key()
        f.choices[1].use_remote()
        eq((f.values.books.book.pending_upload_position or {}).percent, position.percent,
            "waiting or failed chapter open retains local intent: " .. mode)
        if mode == "cancelled" then
            f.sync:cancel_pending_jump("cancelled")
            eq((f.values.books.book.pending_upload_position or {}).percent, position.percent, "cancel preserves local intent")
        elseif mode == "applied" then
            chapter = chapters[2]
            f.sync:on_reader_ready(); f.drain()
            eq(f.values.books.book.pending_upload_position, nil, "applied new chapter supersedes old local intent")
            eq(f.sync.verified, true, "applied cloud chapter verifies")
        end
        eq(#f.uploads, 0, "cloud navigation does not write local checkpoint: " .. mode)
    end
end)

test('failed file resume preserves the previous local intent until real movement',function()
    local f=fixture({})
    f.values.sync.pull_on_open=false
    local saved=f.values.books.book
    local old={book_id='book',chapter_uid=33,chapter_offset=100,percent=50}
    saved.last_local_position=old;saved.pending_upload_position=old;saved.pending_upload_account=f.sync:_account_key()
    f.sync:on_reader_ready()
    local frame=assert(f.sync:begin_file_resume())
    f.drain()
    eq(saved.last_local_position,old,'initial reader timer did not replace the old local point')
    eq(f.sync:checkpoint_local('during_restore'),nil,'pending restore checkpointed the default new-file page')
    eq(f.sync:finish_file_resume(frame,false),true,'failed restore did not finish')
    f.sync:on_page_update()
    eq(f.sync:checkpoint_local('unchanged_failed'),nil,'failed unchanged restore overwrote the previous point')
    eq(saved.pending_upload_position,old,'failed restore discarded unsent intent')
    eq(f.sync:on_network_connected(),false,'failed unchanged file resume started automatic sync')
    f.document.page=f.document.page+1;f.sync:on_page_update()
    eq(f.sync.file_resume,nil,'real movement did not release failed-position protection')
    assert(f.sync:checkpoint_local('actual_movement'))
    eq(saved.pending_upload_position.percent,f.document.page,'real movement did not replace old pending intent')
    eq(#f.uploads,0,'file resume state wrote to cloud')
end)

test('closing or suspending a failed unchanged file resume preserves local records',function()
    local f=fixture({});f.values.sync.pull_on_open=false
    local old={book_id='book',chapter_uid=33,chapter_offset=100,percent=50}
    f.values.books.book.last_local_position=old
    local frame=assert(f.sync:begin_file_resume());assert(f.sync:finish_file_resume(frame,false))
    f.sync:on_suspend();f.sync:on_resume()
    eq(f.sync:checkpoint_local('after_resume'),nil,'suspend/resume released unchanged-failure protection')
    f.sync:on_close_document()
    eq(f.values.books.book.last_local_position,old,'closing an unchanged failed target replaced the original local point')
    eq(f.sync.file_resume,nil,'closed reader retained transient file-resume state')
    eq(#f.uploads,0,'failed restore close uploaded a default new-file page')
end)

test('successful file resume carries local intent without approving a cloud write',function()
    local f=fixture({});f.values.sync.pull_on_open=false
    local old=assert(f.sync:capture_local())
    f.values.books.book.pending_upload_position=old;f.values.books.book.pending_upload_account=f.sync:_account_key()
    local frame=assert(f.sync:begin_file_resume())
    f.document.page=40;f.sync:on_page_update()
    eq(f.sync.local_position.percent,old.percent,'automatic restore movement became a premature checkpoint')
    eq(f.sync:finish_file_resume(frame,true),true,'successful restore did not finish')
    eq(f.values.books.book.pending_upload_position.percent,40,'pending intent was not rebound to the actual new viewport')
    eq(f.values.books.book.last_local_position.percent,40,'restored local point was not persisted')
    eq(f.sync.verified,false,'local file restore granted upload verification')
    eq(#f.uploads,0,'local file restore uploaded progress')
end)

test('file resume refreshes automatic comparison only after success and under its current scope',function()
    for _i,change in ipairs({'success','account','navigation','failure'}) do
        local f=fixture({});local pulls=0
        f.values.sync.pull_on_open=true
        f.sync._pull=function(_self,options) eq(options.manual,false,'file restore used manual write intent');pulls=pulls+1;return true end
        local frame=assert(f.sync:begin_file_resume())
        eq(pulls,0,'file resume compared before locating its source')
        assert(f.sync:finish_file_resume(frame,change~='failure'))
        if change=='account' then f.sync:on_account_changed()
        elseif change=='navigation' then f.sync:begin_local_navigation() end
        f.drain()
        eq(pulls,change=='success' and 1 or 0,'automatic file-resume comparison ignored its final state/scope')
    end
end)

test('file resume departure revokes queued writes and stale frames cannot finish',function()
    local callbacks={}
    local f=fixture({}, {run_online=function(_kind,callback) callbacks[#callbacks+1]=callback;return true end})
    f.values.sync.pull_on_open=false
    local local_position=assert(f.sync:capture_local())
    f.sync:_mark_verified('book','fixture',local_position,{})
    f.sync:_upload_snapshot(local_position,'before_file_resume',false)
    f.sync:begin_file_resume_departure();callbacks[1]()
    eq(#f.uploads,0,'old queued upload survived local file handoff')
    eq(f.sync.verified,false,'old file retained reporting permission')
    local frame=assert(f.sync:begin_file_resume())
    f.sync:on_account_changed()
    eq(f.sync:finish_file_resume(frame,true),false,'old account file-resume result committed')
end)

test("an acknowledgement without exact readback retains intent and stops automatic replay", function()
    for _i, result in ipairs({ { accepted = true }, { accepted = true, position_confirmed = true, acknowledged = false } }) do
        local f = fixture({ progress = 25, chapterUid = 22, chapterIdx = 2, chapterOffset = 150 })
        f.sync:on_reader_ready(); f.drain()
        local calls = 0
        f.sync.upload_position = function() calls = calls + 1; return true, result end
        local point = f.sync:capture_local()
        f.sync:_upload_snapshot(point, "test_unconfirmed", true)
        eq(f.sync.verified, false, "unconfirmed write revokes reporting permission")
        eq(f.values.books.book.last_uploaded_position, nil, "acknowledgement was recorded as confirmed")
        eq(f.values.books.book.pending_upload_position.chapter_offset, point.chapter_offset, "unconfirmed intent lost")
        eq(f.notifications[#f.notifications].code, "upload_unconfirmed", "clear unconfirmed message missing")
        f.document.page = 50; f.sync:on_page_update(); f.sync:on_close_document(); f.drain()
        eq(calls, 1, "close replayed unconfirmed write")
        eq(f.values.books.book.pending_upload_reason, "upload_readback_unconfirmed", "close discarded uncertain status")
    end
end)

test("delayed confirmation polls only reads and retains a newer page", function()
    local f = fixture({ progress = 25, chapterUid = 22, chapterIdx = 2, chapterOffset = 150 })
    f.sync:on_reader_ready(); f.drain()
    local writes, reads, receipt = 0, 0, {}
    f.sync.upload_position = function()
        writes = writes + 1
        return false, { acknowledged = true, error_kind = "confirmation_pending", confirmation = receipt }
    end
    f.sync.confirm_position = function(value)
        eq(value, receipt, "confirmation belongs to initial write")
        reads = reads + 1
        if reads == 1 then return false, { acknowledged = true, error_kind = "confirmation_pending", confirmation = receipt } end
        return true, { acknowledged = true, position_confirmed = true }
    end
    local point = f.sync:capture_local()
    f.sync:_upload_snapshot(point, "test_delayed", true)
    local available, why = f.sync:position_for_report("book")
    eq(available, nil, "periodic reporter crossed pending confirmation")
    eq(why, "progress_confirmation_pending", "pending reporting reason")
    f.step()
    f.document.page = 75; f.sync:on_page_update(); f.sync:checkpoint_local("newer_page")
    f.drain()
    eq(writes, 1, "confirmation resent a write")
    eq(reads, 2, "bounded read count")
    eq(f.values.books.book.last_uploaded_position.percent, point.percent, "receipt bound to newer page")
    eq(f.values.books.book.pending_upload_position.percent, 75, "old confirmation erased newer page")
    eq(f.sync.dirty, true, "new movement is no longer dirty")
end)

test("confirmation exhaustion and cancellation never dispatch another write", function()
    for _i, change in ipairs({ "exhaust", "suspend", "account", "recheck", "source" }) do
        local f = fixture({ progress = 25, chapterUid = 22, chapterIdx = 2, chapterOffset = 150 })
        f.sync:on_reader_ready(); f.drain()
        local writes, reads, receipt = 0, 0, {}
        f.sync.upload_position = function()
            writes = writes + 1
            return false, { acknowledged = true, error_kind = "confirmation_pending", confirmation = receipt }
        end
        f.sync.confirm_position = function()
            reads = reads + 1
            return false, { acknowledged = true, error_kind = "confirmation_pending", confirmation = receipt }
        end
        f.sync:_upload_snapshot(f.sync:capture_local(), "test_pending", true)
        if change == "suspend" then f.sync:on_suspend()
        elseif change == "account" then f.sync:on_account_changed()
        elseif change == "recheck" then f.sync:sync_now()
        elseif change == "source" then f.sync:begin_cloud_source_navigation() end
        f.drain()
        eq(writes, 1, "pending write replayed")
        eq(reads, change == "exhaust" and 2 or 0, "stale or unbounded confirmation read")
        eq(f.values.books.book.last_uploaded_position, nil, "unconfirmed callback committed")
    end
end)

test("an adjacent newer pending coordinate is not cleared by a tolerant receipt", function()
    local callbacks = {}
    local f = fixture({}, { run_online = function(_kind, callback) callbacks[#callbacks + 1] = callback; return true end })
    local point = f.sync:capture_local()
    f.sync:_upload_snapshot(point, "old", false)
    local pending = f.values.books.book.pending_upload_position
    pending.chapter_offset = pending.chapter_offset + 1
    callbacks[1]()
    eq(f.values.books.book.pending_upload_position, pending, "adjacent pending intent cleared")
    eq(f.values.books.book.last_uploaded_position.chapter_offset, point.chapter_offset, "receipt snapshot was mutated")
end)

test("fresh comparisons require exact coordinates for a prior unconfirmed write", function()
    for _i, mode in ipairs({ "adjacent", "missing_index", "same" }) do
        local remote = { progress = 25, chapterUid = 22, chapterIdx = 2, chapterOffset = mode == "adjacent" and 151 or 150 }
        if mode == "missing_index" then remote.chapterIdx = nil end
        local f = fixture(remote)
        f.values.sync.ask_on_conflict = false
        local point = f.sync:capture_local()
        f.values.books.book.pending_upload_position = point
        f.values.books.book.pending_upload_account = f.sync:_account_key()
        f.values.books.book.pending_upload_reason = "upload_readback_unconfirmed"
        f.sync:on_reader_ready(); f.drain()
        if mode == "same" then
            eq(#f.choices, 0, "matching exact readback needs no new decision")
            eq(f.values.books.book.pending_upload_position, nil, "matching cloud coordinate did not resolve pending intent")
        else
            eq(#f.choices, 1, "approximate comparison silently resolved unknown write")
            eq(f.values.books.book.pending_upload_position, point, "uncertain intent lost before explicit decision")
            eq(f.sync.verified, false, "uncertain comparison granted reporting permission")
        end
        eq(#f.uploads, 0, "read-only recheck replayed unknown write")
    end
end)

test("source snapshot becoming ready during confirmation does not resend an unchanged wire position", function()
    local source
    local f = fixture({}, { get_source_position = function() return source end })
    local point = f.sync:capture_local()
    f.sync:_mark_verified("book", "fixture", point, {})
    local writes, receipt = 0, {}
    f.sync.upload_position = function()
        writes = writes + 1
        return false, { acknowledged = true, error_kind = "confirmation_pending", confirmation = receipt }
    end
    f.sync.confirm_position = function()
        return true, { acknowledged = true, position_confirmed = true }
    end
    f.sync:_upload_snapshot(point, "unchanged", false)
    source = { book_id = "book", chapter_uid = "22", chapter_offset = 12345, upload_verified = false }
    f.drain()
    eq(f.sync.dirty, false, "new read-only metadata became a new cloud intent")
    f.sync:on_close_document(); f.drain()
    eq(writes, 1, "close resent the same wire position after source preparation")
end)

test('prepared source wire coordinates preserve local units and clear only their own intent',function()
    local source={book_id='book',chapter_uid='22',chapter_offset=10000,basis='filtered_xhtml_utf16',upload_verified=false,
        file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=1,render_path='chapter.xhtml'}
    local f=fixture({}, {get_source_position=function() return source end})
    local callback
    f.sync.prepare_upload=function(_position,ready) callback=ready;return true end
    local position=assert(f.sync:capture_local())
    f.sync:_mark_verified('book','fixture',position,{})
    local wire={book_id='book',chapter_uid='22',chapter_idx=2,chapter_offset=10000,percent=position.percent,summary='SOURCE_SUMMARY_CANARY'}
    local plan={position=wire,basis='filtered_xhtml_utf16',is_current=function() return true end}
    f.sync.upload_position=function(_book,sent,elapsed,grant)
        eq(sent.chapter_offset,10000,'dispatch uses source coordinate')
        eq(elapsed,0,'source position upload does not add duration')
        eq(grant,plan,'dispatch owns its fresh plan')
        return true,{acknowledged=true,position_confirmed=true}
    end
    f.sync:_upload_snapshot(position,'explicit_local_choice',true)
    eq(f.sync.uploading,true,'asynchronous preparation owns upload slot')
    eq(f.values.books.book.pending_upload_position.chapter_offset,position.chapter_offset,'pending keeps local projection')
    callback(plan)
    local saved=f.values.books.book
    eq(saved.last_uploaded_position.chapter_offset,10000,'uploaded record has actual wire coordinate')
    eq(saved.last_uploaded_position.wire_basis,'filtered_xhtml_utf16','persisted wire coordinate is labelled')
    eq(saved.last_uploaded_position.summary,nil,'source summary was persisted')
    eq(saved.pending_upload_position,nil,'matching original intent was not cleared')
    eq(f.sync.dirty,false,'unchanged source became dirty after upload')
    f.sync:_upload_snapshot(position,'explicit_local_choice',true)
    source.chapter_offset=10001
    f.sync:on_source_position_changed('ready',source)
    f.sync:checkpoint_local('new_source_point')
    callback(plan)
    eq(f.sync.dirty,true,'new same-page source point was lost')
    eq(f.values.books.book.pending_upload_position.source_position.chapter_offset,10001,'old confirmation cleared later source intent')
end)

test('failed and closed source preparations never fall back to estimated uploads',function()
    for _i,mode in ipairs({'failed','closed','expired'}) do
        local f=fixture({})
        local callback
        f.sync.prepare_upload=function(_position,ready) callback=ready;return true end
        local position=assert(f.sync:capture_local())
        f.sync:_upload_snapshot(position,'source_test',false)
        if mode=='closed' then f.sync:on_close_document() end
        local plan
        if mode~='failed' then plan={position=position,is_current=function() return mode~='expired' end} end
        callback(plan,'source_position_unavailable')
        eq(#f.uploads,0,'source failure used old word-coordinate writer')
        eq(f.sync.uploading,false,'source failure retained upload ownership')
        eq(f.values.books.book.pending_upload_position~=nil,true,'source failure lost durable intent')
    end
end)

test('source comparison distinguishes one unit at identical percentages',function()
    local f=fixture({})
    f.sync.prepare_upload=function() end
    local position=assert(f.sync:capture_local())
    position.source_position={book_id='book',chapter_uid='22',chapter_offset=10000,basis='filtered_xhtml_utf16',upload_verified=false}
    local remote={book_id='book',chapter_uid=22,chapter_idx=2,chapter_offset=10001,percent=position.percent,
        has_chapter_offset=true,has_chapter_index=true}
    eq(f.sync:_compare_source(position,remote,chapters),'remote_ahead','one source unit was swallowed by percent tolerance')
    remote.chapter_offset=9999;eq(f.sync:_compare_source(position,remote,chapters),'local_ahead','source ordering was inverted')
    remote.chapter_offset=10000;eq(f.sync:_compare_source(position,remote,chapters),'same','equal source point differs')
    remote.chapter_idx=3;eq(f.sync:_compare_source(position,remote,chapters),nil,'conflicting chapter index accepted')
    remote.chapter_idx=2;remote.book_id='other';eq(f.sync:_compare_source(position,remote,chapters),nil,'foreign source position accepted')
    remote.book_id='book';position.source_position.basis='raw_txt_utf16'
    eq(f.sync:_compare_source(position,remote,chapters),nil,'TXT borrowed XHTML cloud semantics')
    remote.source='web'
    eq(f.sync:_compare_source(position,remote,chapters),'same','validated raw TXT comparison was not enabled')
    remote.chapter_offset=10001
    eq(f.sync:_compare_source(position,remote,chapters),'remote_ahead','raw UTF16 one-unit movement was lost')
    remote.source='gateway'
    eq(f.sync:_compare_source(position,remote,chapters),nil,'gateway coordinates became raw TXT without proof')
end)

test('source progress keeps server percentages and compares exact coordinates',function()
    local source={book_id='book',chapter_uid='22',chapter_offset=10000,basis='filtered_xhtml_utf16',upload_verified=false}
    local f=fixture({bookId='book',progress=37,chapterUid=22,chapterIdx=2,chapterOffset=10001,summary='SOURCE_SUMMARY_CANARY'},
        {get_source_position=function() return source end})
    f.sync.prepare_upload=function() end
    local remote=f.sync:_fetch_remote('book',chapters)
    eq(remote.percent,37,'source offset was divided by catalog words to invent a percent')
    eq(remote.chapter_offset,10001,'remote source offset was clamped to word count')
    eq(remote.summary,nil,'remote source text entered position checkpoint')
    local position=assert(f.sync:capture_local());position.percent=37
    f.sync:_resolve(position,remote,{book_id='book',book=f.values.books.book,chapters=chapters},{manual=true})
    eq(f.sync.state,'awaiting_choice','same percent swallowed a one-unit source difference')
    eq(#f.choices,1,'source difference did not reach the normal choice dialog')
    local applied
    f.sync.apply_source_remote=function(value) applied=value;return true end
    f.choices[1].use_remote()
    eq(applied.chapter_offset,10001,'cloud choice did not use original source offset')
    eq(#f.jumps,0,'cloud choice fell back to a word fraction')
end)

test('read-only source navigation and normal sync choices keep separate reporting gates',function()
    local f=fixture({})
    f.sync.prepare_upload=function() end
    local point={book_id='book',chapter_uid='22',chapter_offset=10000,basis='filtered_xhtml_utf16',upload_verified=false}
    f.sync.current_source_target=function() return point end
    f.sync.verified=true
    eq(f.sync:accept_cloud_source_target(point),true,'read-only source target was rejected')
    eq(f.sync.verified,false,'read-only location tool granted reporting authority')
    eq(f.sync:accept_cloud_source_target(point,true),true,'normal cloud sync choice was rejected')
    eq(f.sync.verified,true,'normal source choice did not finish its sync decision')
    eq(f.sync.local_position.source_position.upload_verified,false,'sync choice flipped source metadata upload flag')
end)

test('closed source plan survives document generation but releases on terminal confirmation',function()
    local source={book_id='book',chapter_uid='22',chapter_offset=10000,basis='filtered_xhtml_utf16',upload_verified=false,
        file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=1,render_path='chapter.xhtml'}
    local f=fixture({}, {get_source_position=function() return source end})
    f.sync.prepare_upload=function() error('closed document used live preparation') end
    local token,ready={},nil
    f.sync.freeze_close=function(position) eq(position.source_position.chapter_offset,10000,'close did not freeze source');return token end
    f.sync.prepare_closed=function(value,_position,callback) eq(value,token,'close lost opaque token');ready=callback;return true end
    local position=assert(f.sync:capture_local())
    f.sync:_mark_verified('book','fixture',position,{})
    f.sync.dirty=true
    local captured,frozen=f.sync:prepare_close(source)
    eq(captured,token,'eligible close did not freeze')
    f.sync:on_close_document(source,captured,frozen)
    eq(f.sync.uploading,true,'close did not retain asynchronous work')
    local released=0
    local plan={position={book_id='book',chapter_uid='22',chapter_idx=2,chapter_offset=10000,percent=position.percent},
        basis='filtered_xhtml_utf16',source_position=source,detached=true,is_current=function() return true end,
        release=function() released=released+1 end}
    ready(plan)
    eq(#f.uploads,1,'closed generation rejected detached source plan')
    eq(released,1,'confirmed close retained detached plan')
    eq(f.sync.verified,false,'close reactivated closed reader')
    eq(f.values.books.book.last_uploaded_position.chapter_offset,10000,'close wrote old projection')
    eq(f.values.books.book.pending_upload_position,nil,'closed acknowledgement did not clear own intent')
end)

test('superseded dispatch acknowledgement cannot clear a newer pending record',function()
    local f=fixture({})
    local finished,released=0,0
    f.sync.source_dispatch={pending=function() return false end,begin=function() return {} end,
        owns=function() return true end,finish=function() finished=finished+1;return false end}
    f.sync.prepare_upload=function(position,ready)
        ready{position=position,is_current=function() return true end,release=function() released=released+1 end}
    end
    f.sync.upload_position=function(_id,_position,_seconds,plan)
        eq(plan.before_send(),true,'source dispatch did not start')
        return true,{acknowledged=true,position_confirmed=true}
    end
    local position=assert(f.sync:capture_local())
    f.sync:_mark_verified('book','fixture',position,{})
    f.sync:_upload_snapshot(position,'explicit_local_choice',false)
    eq(finished,1,'terminal result did not check dispatch ownership')
    eq(released,1,'superseded plan was retained')
    eq(f.values.books.book.last_uploaded_position,nil,'superseded result was saved as uploaded')
    eq(f.values.books.book.pending_upload_position~=nil,true,'superseded result cleared pending intent')
end)

test('source dispatch interruption keeps journal and blocks replay until explicit comparison',function()
    local source={book_id='book',chapter_uid='22',chapter_offset=10000,basis='filtered_xhtml_utf16',upload_verified=false,
        file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=1,render_path='chapter.xhtml'}
    local f=fixture({}, {get_source_position=function() return source end})
    local journal=require('weread.lib.source_dispatch'):new{settings=f.sync.settings,nonce=function() return string.rep('a',32) end}
    f.sync.source_dispatch=journal
    f.sync.prepare_upload=function(position,callback)
        callback{position={book_id='book',chapter_uid='22',chapter_idx=2,chapter_offset=10000,percent=position.percent},
            source_position=source,basis='filtered_xhtml_utf16',is_current=function() return true end}
    end
    local sends=0
    f.sync.upload_position=function(_book,_position,_elapsed,plan)
        eq(plan.before_send(),true,'dispatch did not reserve before first HTTP')
        eq(plan.before_send(),true,'same dispatch could not check before second HTTP')
        sends=sends+1;f.sync:on_network_disconnected()
        return false,{error_kind='unconfirmed',report_attempted=true}
    end
    local position=assert(f.sync:capture_local())
    f.sync:_mark_verified('book','fixture',position,{})
    f.sync:_upload_snapshot(position,'explicit_local_choice',true)
    eq(journal:pending('book'),true,'interrupted generation lost journal')
    f.sync:_upload_snapshot(position,'document_close',false)
    eq(sends,1,'interrupted dispatch was replayed on close')
    f.sync.verified=true
    local value,why=f.sync:position_for_report('book')
    eq(value,nil,'unresolved dispatch granted periodic position')
    eq(why,'progress_confirmation_pending','journal did not explain reporting pause')
    local remote={book_id='book',chapter_uid=22,chapter_idx=2,chapter_offset=10000,percent=position.percent,
        has_chapter_offset=true,has_chapter_index=true}
    f.sync:_resolve(position,remote,{book_id='book',book=f.values.books.book,chapters=chapters},{manual=true})
    eq(journal:pending('book'),false,'exact read-only comparison did not retire uncertainty')
    eq(sends,1,'read-only comparison resent a write')
end)

test('native asynchronous dispatch bypasses Web sender and journal and preserves later intent',function()
    for _i,mode in ipairs({'confirmed','unknown','newer','readonly'}) do
        local source={book_id='book',chapter_uid='22',chapter_offset=10001,basis='raw_txt_utf16',upload_verified=false,
            file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=7,render_path='OEBPS/text/chapter.xhtml'}
        local f=fixture({}, {get_source_position=function() return source end})
        local point=assert(f.sync:capture_local())
        local remote={book_id='book',chapter_uid=22,chapter_idx=2,chapter_offset=10000,raw_percent=20,percent=20,
            source='web',has_chapter_offset=true,has_chapter_index=true}
        local delivered,sends,releases=nil,0,0
        local plan={transport='native_position',basis='raw_txt_utf16',source_position=source,is_current=function() return true end,
            position={book_id='book',chapter_uid='22',chapter_idx=2,chapter_offset=10001,percent=point.percent,summary='RAW_SUMMARY_CANARY'},
            release=function() releases=releases+1 end,
            dispatch=function(cb) sends=sends+1;delivered=cb;return true end}
        f.sync.source_dispatch={pending=function() return false end,begin=function() error('native entered Web journal') end}
        f.sync.upload_position=function() error('native entered Web sender') end
        f.sync.prepare_upload=function(intent,ready)
            eq(intent.native_position_only,true,'native route did not distinguish time reporting')
            eq(intent.expected_remote.chapter_offset,10000,'cloud decision was not pinned')
            ready(plan);return true
        end
        f.sync:_mark_verified('book','fixture',point,remote)
        f.sync:_upload_snapshot(point,'explicit_local_choice',true)
        eq(f.sync.uploading,true,'native async slot closed before result')
        eq(sends,1,'native dispatcher did not start exactly once')
        eq(f.values.books.book.last_uploaded_position,nil,'preparation claimed a completed upload')
        if mode=='newer' then
            source.chapter_offset=10002;f.sync:on_source_position_changed('ready',source);f.sync:checkpoint_local('later')
        end
        local accepted=mode~='unknown'
        delivered(true,accepted,{acknowledged=mode~='readonly' and accepted,position_confirmed=accepted,
            read_only_confirmation=mode=='readonly',report_attempted=mode~='readonly',
            error_kind=not accepted and 'unconfirmed' or nil,error=not accepted and 'upload_readback_unconfirmed' or nil})
        eq(f.sync.uploading,false,'native completion retained upload slot')
        eq(releases,1,'native lease was not released')
        if mode=='unknown' then
            eq(f.values.books.book.pending_upload_reason,'upload_readback_unconfirmed','unknown dispatch lost durable intent')
            eq(f.sync.verified,false,'unknown native result granted automatic synchronization')
        elseif mode=='newer' then
            eq(f.values.books.book.pending_upload_position.source_position.chapter_offset,10002,'old completion erased a newer source point')
            eq(f.sync.dirty,true,'new native source became clean')
        else
            eq(f.values.books.book.last_uploaded_position.wire_basis,'raw_txt_utf16','native coordinate basis was lost')
            eq(f.values.books.book.last_uploaded_position.summary,nil,'native summary persisted in checkpoint')
            eq(f.values.books.book.pending_upload_position,nil,'completed own native intent remained pending')
        end
    end
end)

test('raw close freezes cloud decision and finishes asynchronously after reader generation closes',function()
    local source={book_id='book',chapter_uid='22',chapter_offset=10001,basis='raw_txt_utf16',upload_verified=false,
        file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=7,render_path='OEBPS/text/chapter.xhtml'}
    local f=fixture({}, {get_source_position=function() return source end})
    local position=assert(f.sync:capture_local())
    local remote={book_id='book',chapter_uid=22,chapter_idx=2,chapter_offset=10000,raw_percent=20,percent=20,
        source='web',has_chapter_offset=true,has_chapter_index=true}
    local frozen,ready,done;local token={};local sends,releases=0,0
    f.sync.freeze_close=function(intent) frozen=intent;return token end
    f.sync.prepare_closed=function(receipt,intent,callback)
        eq(receipt,token,'raw close lost opaque token');eq(intent.native_position_only,nil,'route flag entered saved position')
        eq(intent.expected_remote,nil,'cloud decision entered saved position');ready=callback;return true
    end
    f.sync.prepare_upload=function() error('closed raw point used live document') end
    f.sync.upload_position=function() error('closed raw point used Web sender') end
    f.sync:_mark_verified('book','fixture',position,remote);f.sync.dirty=true
    local captured,closed=f.sync:prepare_close(source)
    eq(frozen.native_position_only,true,'close did not opt into native-only route')
    eq(frozen.expected_remote.chapter_offset,10000,'close lost last cloud decision')
    f.sync.remote_position.chapter_offset=999
    eq(frozen.expected_remote.chapter_offset,10000,'later decision mutated close snapshot')
    f.sync:on_close_document(source,captured,closed)
    ready{position={book_id='book',chapter_uid='22',chapter_idx=2,chapter_offset=10001,percent=position.percent},
        basis='raw_txt_utf16',transport='native_position',source_position=source,detached=true,is_current=function() return true end,
        dispatch=function(cb) sends=sends+1;done=cb;return true end,release=function() releases=releases+1 end}
    eq(sends,1,'closed native generation did not dispatch');eq(f.sync.uploading,true,'async close ended early')
    done(true,true,{acknowledged=true,position_confirmed=true})
    eq(releases,1,'closed raw receipt leaked');eq(f.sync.verified,false,'closed completion reactivated reader')
    eq(f.values.books.book.last_uploaded_position.wire_basis,'raw_txt_utf16','closed raw basis was lost')
    eq(f.values.books.book.pending_upload_position,nil,'closed confirmed raw point retained its intent')
end)
test('failed close freezing retains intent without trying live preparation after stop',function()
    local f=fixture({});local position=assert(f.sync:capture_local())
    f.sync.freeze_close=function() return nil end
    f.sync.prepare_upload=function() error('failed freeze touched stopped live source') end
    f.sync:_mark_verified('book','fixture',position,{});f.sync.dirty=true
    local token,closed=f.sync:prepare_close()
    f.sync:on_close_document(nil,token,closed)
    eq(f.sync.uploading==true,false,'failed freeze started upload')
    eq(f.values.books.book.pending_upload_position~=nil,true,'failed freeze discarded local intent')
end)

test('native review preserves current intent and requires a fresh choice with prompts disabled',function()
    for _i,choice in ipairs({'local','cloud'}) do
        local f=fixture({bookId='book',progress=50,chapterUid=33,chapterIdx=3,chapterOffset=100})
        f.values.sync.pull_on_open=false;f.values.sync.ask_on_conflict=false
        f.sync:on_reader_ready();f.drain()
        local old=assert(f.sync:capture_local());f.sync:_mark_verified('book','fixture',old,{})
        f.sync.dirty=true;f.sync:checkpoint_local('older_pending')
        f.document.page=40;f.sync:begin_native_review()
        eq(f.values.books.book.pending_upload_position.percent,40,'review erased new movement')
        eq(f.sync.verified,false,'review retained old sender authority')
        eq(#f.uploads,0,'begin review sent a request')
        assert(f.sync:compare_after_native_review());f.drain()
        eq(#f.choices,1,'review reused automatic keep-local policy')
        eq(#f.uploads,0,'archive comparison sent before new choice')
        eq(f.values.books.book.pending_upload_position.percent,40,'comparison erased current local intent')
        if choice=='local' then f.choices[1].keep_local();eq(#f.uploads,1,'new explicit local choice could not sync')
        else f.choices[1].use_remote();eq(#f.uploads,0,'cloud choice sent a write') end
    end
end)

test('raw TXT cloud choice accepts only the applied held source and keeps source units',function()
    local point={book_id='41',chapter_uid='22',chapter_offset=1200,file_id=string.rep('a',64),book_version=7,
        raw_sha256=string.rep('b',64),render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=false}
    local f=fixture({}, {get_source_position=function() return point end})
    f.sync.prepare_upload=function() error('cloud choice dispatched local upload') end
    f.sync.current_source_target=function() return point end
    f.sync.get_chapters=function(book) assert(type(book)=='table');return chapters end
    f.sync.detect_book=function() return '41' end;f.values.books['41']=f.values.books.book;f.values.books['41'].book_id='41'
    f.sync.current_book_id='41';f.sync.dirty=true;f.sync:checkpoint_local('pending_before_cloud')
    local wrong={};for k,v in pairs(point) do wrong[k]=v end;wrong.basis='unknown'
    eq(f.sync:accept_cloud_source_target(wrong,true),false,'unknown source unit accepted')
    wrong.basis='raw_txt_utf16';wrong.chapter_offset=1201
    eq(f.sync:accept_cloud_source_target(wrong,true),false,'wrong applied TXT target accepted')
    local remote={book_id='41',chapter_uid='22',chapter_offset=1200,percent=25,raw_sha256=point.raw_sha256,raw_bytes=2000,basis='raw_txt_utf16',upload_verified=false}
    eq(f.sync:accept_cloud_source_target(point,true),false,'local TXT target gained cloud authority without a checked remote')
    eq(f.sync:accept_cloud_source_target(point,true,remote),true,'exact applied TXT target rejected')
    eq(f.sync.verified,true,'explicit raw cloud choice did not complete verification')
    eq(f.sync.source_local_anchor.basis,'raw_txt_utf16','TXT source basis replaced')
    eq(f.sync.source_local_anchor.chapter_offset,1200,'TXT source point replaced by local proportional point')
    eq(f.values.books['41'].pending_upload_position,nil,'applied cloud choice retained old local intent')
    eq(#f.uploads,0,'cloud choice posted a position')
end)

print(string.format(
    "progress_sync_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
