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
    local out = assert(io.open(assert(os.getenv("WEREAD_EVIDENCE")) .. "/progress-confirmation-result.json", "wb"))
    out:write(Json.encode{ result = "PASS", synthetic_only = true, account_data_writes_attempted = 0,
        cases = cases, automatic_write_retries = 0, authorization_posts = 0, native_location_preserved = true,
        pending_intent_preserved = true, explicit_recheck_recovered = true }); out:close()
end
