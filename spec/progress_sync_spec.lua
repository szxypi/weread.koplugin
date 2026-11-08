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
            return true, { accepted = true }
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
        return true, { accepted = true }
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

print(string.format(
    "progress_sync_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
