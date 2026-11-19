-- Actual candidate controls, HTTP and SQLite; synthetic accounts only.
return function(reader, plugin, pump, shot, clean_popups)
    local Json, HTTP, LTN = require("json"), require("socket.http"), require("ltn12")
    local UI = require("ui/uimanager")
    local function request(path, data)
        local chunks, raw = {}, data and Json.encode(data)
        local _, code = HTTP.request{ url = plugin.settings.mock_endpoint .. path, proxy = plugin.settings.mock_endpoint,
            method = raw and "POST" or "GET", source = raw and LTN.source.string(raw),
            headers = raw and { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#raw) } or {},
            sink = LTN.sink.table(chunks) }
        assert(code == 200); return Json.decode(table.concat(chunks))
    end
    local function writes()
        local result = 0
        for _i, row in ipairs(request("/__state").totals) do
            if row.path == "/web/book/read" then result = result + row.count end
            assert(row.path ~= "/web/login/renewal", "position confirmation renewed authorization")
        end
        return result
    end
    local book_id = assert(plugin:detectWeReadBook())
    local function sync()
        clean_popups(reader)
        assert(plugin:onWeReadSyncProgress())
        pump(function() return not plugin.progress_sync.pulling end)
        local choice = UI:getTopmostVisibleWidget()
        if choice and choice.cancel_text == require("weread.lib.plugin_util").tr("Keep KOReader progress") then
            choice.cancel_callback(); UI:close(choice)
        end
        pump(function() return not plugin.progress_sync.uploading end)
    end
    local cases = {}
    for _i, mode in ipairs({ "delayed", "stale", "noack" }) do
        request("/__control", { progress_confirmation = mode })
        reader.rolling:onGotoPage(reader:getCurrentPage() == 1 and reader.document:getPageCount() or 1)
        local before, origin = writes(), reader.document:getXPointer()
        local prior = plugin.settings:get_book(book_id).last_upload_at
        sync()
        local saved = plugin.settings:get_book(book_id)
        local reads = request("/__state").confirmation_reads
        assert(writes() == before + 1, "one position report was refreshed or replayed")
        assert(reader.document:getXPointer() == origin, "confirmation navigated the reader")
        if mode == "delayed" then
            assert(reads == 3 and not saved.pending_upload_position and plugin.progress_sync.verified,
                "delayed exact readback did not finish")
        else
            assert(reads == (mode == "stale" and 3 or 0) and saved.pending_upload_position and not plugin.progress_sync.verified,
                "unconfirmed result lost local intent or retained reporting authority")
            assert(saved.last_upload_at == prior, "unconfirmed write was recorded as uploaded")
            local message = assert(UI:getTopmostVisibleWidget())
            assert(message.text == require("weread.lib.plugin_util").tr(
                "The cloud position could not be confirmed.\nYour local position is kept. This upload will not be sent again automatically. Please sync again later to compare positions."),
                "native unconfirmed explanation missing")
            if mode == "stale" then shot("reading-upload-unconfirmed") end
            plugin:onFlushSettings()
            assert(writes() == before + 1 and plugin.settings:get_book(book_id).pending_upload_position,
                "flush replayed or cleared unconfirmed intent")
            assert(plugin.settings:get_book(book_id).pending_upload_reason == "upload_readback_unconfirmed",
                "flush lost the durable unconfirmed state")
        end
        cases[#cases + 1] = { mode = mode, report_posts = 1, readback_gets = reads, result = "PASS" }
    end
    request("/__control", { progress_confirmation = "plain" })
    sync()
    assert(not plugin.settings:get_book(book_id).pending_upload_position and plugin.progress_sync.verified,
        "explicit new comparison did not restore normal synchronization")
    -- Move while the accepted position is waiting for delayed readback. The
    -- newer page must already be durable when the confirmation arrives.
    request("/__control", { progress_confirmation = "delayed" })
    clean_popups(reader)
    reader.rolling:onGotoPage(reader:getCurrentPage() == 1 and reader.document:getPageCount() or 1)
    local before = writes()
    assert(plugin:onWeReadSyncProgress())
    pump(function() return not plugin.progress_sync.pulling end)
    local choice = UI:getTopmostVisibleWidget()
    if choice and choice.cancel_text == require("weread.lib.plugin_util").tr("Keep KOReader progress") then
        choice.cancel_callback(); UI:close(choice)
    end
    pump(function() return writes() == before + 1 or not plugin.progress_sync.uploading end)
    assert(plugin.progress_sync.uploading, "delayed confirmation did not remain in flight")
    reader.rolling:onGotoPage(reader:getCurrentPage() == 1 and reader.document:getPageCount() or 1)
    plugin.progress_sync:on_page_update()
    local moved = assert(plugin.progress_sync:capture_local())
    pump(function() return not plugin.progress_sync.uploading end)
    assert(writes() == before + 1, "movement during confirmation replayed the upload")
    local reopened = require("weread.lib.settings"):new():get_book(book_id)
    local same = require("weread.lib.position_mapper").same_position
    assert(reopened and same(reopened.last_local_position, moved)
        and same(reopened.pending_upload_position, moved), "newer page was not committed to durable storage")
    assert(reopened.pending_upload_account == plugin.progress_sync:_account_key()
        and plugin.progress_sync.dirty, "newer page lost its pending owner or dirty state")
    cases[#cases + 1] = { mode = "movement_during_confirmation", report_posts = 1, result = "PASS" }
    -- Exercise the actual native viewport and SQLite with a deliberately
    -- rounded synthetic coordinate and a no-network confirmation callback.
    local original = assert(plugin.settings:get_book(book_id))
    local state_fields = { "last_local_position", "last_local_account", "pending_upload_position",
        "pending_upload_reason", "pending_upload_account", "last_uploaded_position", "last_upload_at",
        "last_sync_error", "last_remote_position", "unindexed_resume", "cb_cloud_view_resume" }
    local restore = {}
    for _i, field in ipairs(state_fields) do
        if original[field] == nil then restore[field] = false else restore[field] = original[field] end
    end
    local actual = plugin.progress_sync
    local callback, fixed
    local fake = require("weread.lib.progress_sync"):new{
        settings = plugin.settings, client = {}, scheduler = { scheduleIn = function() end },
        get_document = function() return reader.document end,
        detect_book = function() return book_id end,
        get_book = function(id) return plugin.settings:get_book(id) end,
        get_chapters = function() return {} end, get_file_context = function() end,
        get_view_mode = actual.get_view_mode, get_viewport_height = actual.get_viewport_height,
        run_online = function(_kind, cb) callback = cb; return true end,
        upload_position = function() return true, { acknowledged = true, position_confirmed = true } end,
        goto_fraction = function() return true end, open_chapter = function() return true end,
    }
    function fake:capture_local()
        local value = assert(actual:capture_local())
        if not fixed then
            fixed = { chapter_uid = value.chapter_uid, chapter_idx = value.chapter_idx,
                chapter_offset = value.chapter_offset, percent = value.percent }
        end
        for key, v in pairs(fixed) do value[key] = v end
        value.source_position, value.source_view = nil, nil
        return value
    end
    fake.current_book_id, fake.verified = book_id, true
    local first = assert(fake:capture_local());fake.local_position = first
    assert(fake:_upload_snapshot(first, 'synthetic_rounded_position', false))
    reader.rolling:onGotoPage(reader:getCurrentPage() == 1 and reader.document:getPageCount() or 1)
    fake:on_page_update()
    local newer = assert(fake:capture_local())
    assert(newer.fraction ~= first.fraction and require('weread.lib.progress_readback').same_wire_position(first, newer),
        'synthetic native positions did not share a rounded coordinate')
    assert(callback);callback()
    local disk = assert(require("weread.lib.settings"):new():get_book(book_id))
    assert(math.abs(disk.last_local_position.fraction - newer.fraction) < 1e-12
        and disk.pending_upload_position and math.abs(disk.pending_upload_position.fraction - newer.fraction) < 1e-12
        and fake.dirty, 'same-coordinate page was not preserved on disk')
    assert(plugin.settings:patch_reading_state(book_id, restore))
    assert(writes() == before + 1, 'synthetic rounded-position check sent a network write')
    cases[#cases + 1] = { mode = "same_rounded_coordinate", report_posts = 0, result = "PASS" }
    local out = assert(io.open(assert(os.getenv("WEREAD_EVIDENCE")) .. "/progress-confirmation-result.json", "wb"))
    out:write(Json.encode{ result = "PASS", synthetic_only = true, account_data_writes_attempted = 0,
        cases = cases, automatic_write_retries = 0, authorization_posts = 0, native_location_preserved = true,
        pending_intent_preserved = true, explicit_recheck_recovered = true }); out:close()
end
