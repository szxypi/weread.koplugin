-- Requires the real statistics plugin and an isolated mock account.
return function(reader, request_count, flush_tasks)
    local UIManager = require("ui/uimanager")
    local plugin, stats = reader.weread, assert(reader.statistics, "native statistics plugin missing")
    assert(stats:isEnabledAndNotFrozen() and stats.id_curr_book, "native statistics not initialized")
    local collector = plugin.offline_time
    local FileIdentity = require("weread.lib.book_file_identity")
    local file_book_id = assert(plugin:detectWeReadBook())
    local original_identity = FileIdentity.read_document(reader.document, file_book_id)
    assert(original_identity.book_version == 7 and original_identity.version_source == "epub_snapshot",
        "downloaded EPUB did not retain source version through the native engine")
    local records = plugin.settings:get("books")
    records[file_book_id].bookVersion = 99
    plugin.settings:set("books", records)
    plugin.settings:flush()
    local original_online = plugin.isNetworkConnected
    plugin.isNetworkConnected = function() return false end
    plugin.settings:set("offline_time", { enabled = true })
    plugin.settings:flush()
    local writes = request_count("/web/book/read")
    local started=collector:start()
    assert(started and collector.active, "offline collector did not start with native statistics: state="..tostring(collector.state)
        .." stats_paused="..tostring(stats._reading_paused_ts~=nil).." reader_visible="..tostring(UIManager:getTopmostVisibleWidget()==reader))
    local first_start = collector.active.last_seen
    -- Real wall/monotonic clocks and a genuine page dwell, without changing
    -- native tuples, its counters, clock values or ledger data.
    require("socket").sleep(6)
    assert(collector:update("timer"), "native statistics collection failed")
    local first = collector:status().pending
    assert(first >= 5 and first == collector.active.last_seen - first_start, "actual dwell was not captured exactly once: " .. tostring(first))
    local first_endpoint = collector.active.last_seen
    assert(collector:update("timer"), "repeated native capture failed")
    -- Consecutive real-clock calls can cross a second boundary. Only new wall
    -- time may be added; the preceding six-second prefix must not be replayed.
    assert(collector:status().pending - first == collector.active.last_seen - first_endpoint,
        "repeated native capture duplicated time or lost newly elapsed time")
    reader:handleEvent(require("ui/event"):new("ReadingPaused"))
    assert(not collector.active and not collector.task, "native pause retained collector")
    local paused = collector:status().pending
    local Content = require("weread.lib.content")
    local replacement_book = plugin.settings:get("books")[file_book_id]
    replacement_book.bookVersion = 8
    local catalog = assert(Content.load_catalog_cache(plugin.client, plugin.settings, replacement_book))
    local original_text = assert(reader.document:getDocumentFileContent("OEBPS/text/chapter.xhtml"))
    local replaced_path = Content.save_chapter_epub(plugin.settings, replacement_book, catalog[1], original_text, {}, nil,
        FileIdentity.capture(replacement_book))
    assert(replaced_path == reader.document.file, "fixture did not replace the active pathname")
    assert(FileIdentity.read_document(reader.document, file_book_id).file_id == original_identity.file_id,
        "background replacement rebound the open reader to a new file")
    require("socket").sleep(2)
    assert(collector:status().pending == paused, "paused time became reading")
    reader:handleEvent(require("ui/event"):new("ReadingResumed"))
    flush_tasks()
    assert(collector.active, "native resume did not create a new collection window")
    local resume_start = collector.active.last_seen
    require("socket").sleep(6)
    assert(collector:update("timer"), "resumed capture failed")
    local total = collector:status().pending
    assert(total - paused >= 5 and total - paused == collector.active.last_seen - resume_start,
        "resumed page replayed its prefix or included the pause")
    -- A native flush moves the same tuples from memory into statistics.sqlite3.
    local before_flush = collector.active.last_seen
    stats:insertDB()
    assert(collector:update("timer") and collector:status().pending - total == collector.active.last_seen - before_flush,
        "native DB flush replayed captured tuples")
    reader:handleEvent(require("ui/event"):new("ReadingPaused"))
    total = collector:status().pending
    plugin:showOfflineTimeStatus()
    UIManager:forceRePaint()
    require("device").screen:shot(os.getenv("KO_HOME") .. "/../evidence/offline-time-status.png")
    local message = UIManager._window_stack[#UIManager._window_stack].widget
    UIManager:close(message)
    assert(request_count("/web/book/read") == writes, "local collection unexpectedly uploaded time")
    collector:stop("disabled")
    plugin.settings:set("offline_time", { enabled = false })
    plugin.settings:flush()
    collector:start()
    assert(not collector.active and not collector.task, "disabled collector retained a task")
    local key = plugin.library_db:accountKey()
    local Store = require("weread.lib.offline_time_store")
    local persisted = Store:new(plugin.settings.data_dir)
    assert(persisted:recover(key) and persisted:summary(key).pending == total, "ledger reopening changed captured time")
    for _, row in ipairs(assert(persisted:pending(key))) do
        assert(row.book_version == 7 and row.file_id == original_identity.file_id and row.version_source == "epub_snapshot",
            "offline ledger used a library/replacement version instead of the still-open EPUB")
    end
    local account = plugin.settings:get("account")
    plugin.settings:set("account", { user_vid = "900098", name = "Other mock" })
    plugin:onWeReadAccountChanged()
    assert(collector:status().pending == 0, "offline time crossed accounts")
    plugin.settings:set("account", account)
    plugin.settings:flush()
    plugin:onWeReadAccountChanged()
    assert(collector:status().pending == total, "original account lost its offline time")
    plugin.isNetworkConnected = original_online
    reader:handleEvent(require("ui/event"):new("ReadingResumed"))
    print("PASS: native statistics dwell/pause/resume/DB flush -> offline account ledger; no network writes; seconds=" .. total)
    local original_path = reader.document.file
    return function()
        local document = assert(require("document/documentregistry"):openDocument(original_path))
        assert(document:loadDocument(false), "replacement EPUB did not load")
        local identity = FileIdentity.read_document(document, file_book_id)
        assert(identity.book_version == 8 and identity.file_id ~= original_identity.file_id,
            "reopened EPUB did not use its replacement source version")
        document:close()
        print("PASS: EPUB source 7 survives library 99 and active-path replacement 8; reopen binds version 8")
    end
end
