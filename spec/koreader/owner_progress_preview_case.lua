-- Real-source preview of the actual upload service. No dispatch function is
-- available here. The enter acknowledgement is synthetic; reports throw
-- before transport. This never proves a real write or grants upload rights.
return function(input, counters)
    local Json, Protocol = require("json"), require("weread.lib.protocol")
    local Crypto = require("weread.lib.crypto")
    local config = assert(input.progress_preview)
    local case = { active = false, records = Json.decode("[]"), report = {
        source_points_verified = false, reader_position_restored = false, source_upload_gate_preserved = false,
        actual_upload_service = false, all_reports_unconfirmed = false, legacy_matches_source = false, page_start_matches_source = false,
        captured_requests = 0, synthetic_enter_acknowledgements = 0, denied_requests = 0, network_write_dispatches = 0,
        failed_line = 0,
    } }
    assert(input.source_format == "web_xhtml" and type(config.baseline) == "table" and type(config.target) == "table")
    local baseline, target = config.baseline, config.target
    assert(baseline.book_id == input.book_id and target.book_id == input.book_id)
    assert(tostring(baseline.chapter_uid) == input.chapter_uid and tostring(target.chapter_uid) == input.chapter_uid)
    assert(type(baseline.chapter_offset) == "number" and baseline.chapter_offset % 1 == 0 and baseline.chapter_offset >= 0)
    assert(target.chapter_offset == baseline.chapter_offset + 1 and baseline.chapter_idx == target.chapter_idx)
    assert(type(baseline.raw_percent) == "number" and baseline.raw_percent % 1 == 0
        and baseline.raw_percent >= 0 and baseline.raw_percent <= 100 and target.raw_percent == baseline.raw_percent)
    local stages = { "write_enter", "write_same", "write_probe", "write_restore" }
    local function point(stage) return stage == "write_probe" and target or baseline end
    local function reject()
        counters[30] = counters[30] + 1
        error("progress preview scope rejected", 0)
    end
    function case:is_write(options) return options.url == "https://weread.qq.com/web/book/read" end
    function case:request(client, options)
        local h = options.headers or {}
        local index = #self.records + 1
        local stage = stages[index]
        if not self.active or not stage or options.method ~= "POST" or options.sink or options.skip_cookie
            or options.sensitive ~= true or h.Cookie or h.cookie or h.Authorization or h.authorization
            or h.vid or h.accessToken or client.settings:get("cookies", {}).wr_vid ~= input.vid
            or type(options.body) ~= "string" or #options.body > 16384 then return reject() end
        local valid, body = pcall(Json.decode, options.body)
        if not valid or type(body) ~= "table" then return reject() end
        local p = point(stage)
        local enter = stage == "write_enter"
        local expected = { appId = true, b = true, c = true, ci = true, co = true, sm = true, pr = true,
            ct = true, ps = true, pc = true, s = true }
        if not enter then expected.rt, expected.ts, expected.rn, expected.sg = true, true, true, true end
        local count = 0
        for key in pairs(body) do if not expected[key] then return reject() end; count = count + 1 end
        local book = client.settings:get_book(input.book_id)
        if not book or count ~= (enter and 11 or 15) or body.appId ~= Protocol.web_app_id()
            or body.b ~= Protocol.e(input.book_id) or body.c ~= Protocol.e(input.chapter_uid)
            or body.ci ~= p.chapter_idx or body.co ~= p.chapter_offset or body.pr ~= p.raw_percent
            or body.sm ~= Protocol.utf8_substr(p.summary, 20) or body.ps ~= book.psvts or body.pc ~= book.pclts
            or type(body.ct) ~= "number" or body.ct % 1 ~= 0 or math.abs(os.time() - body.ct) > 30
            or h.Referer ~= (book.reader_url or Protocol.reader_url(input.book_id)) then return reject() end
        local signed = {}; for key, value in pairs(body) do if key ~= "s" then signed[key] = value end end
        if body.s ~= Protocol.sign(Protocol.sorted_query(signed)) then return reject() end
        local token = book.token or Protocol.DEFAULT_READER_TOKEN
        if token == "" then token = Protocol.DEFAULT_READER_TOKEN end
        if not enter and (body.rt ~= 0 or type(body.ts) ~= "number" or body.ts % 1 ~= 0 or math.floor(body.ts / 1000) ~= body.ct
            or type(body.rn) ~= "number" or body.rn % 1 ~= 0 or body.rn < 0 or body.rn > 999
            or body.sg ~= Crypto.sha256_hex(tostring(body.ts) .. tostring(body.rn) .. token)) then return reject() end
        self.records[#self.records + 1] = { stage = stage, body = body,
            context = { psvts = book.psvts, pclts = book.pclts, token = token } }
        self.report.captured_requests = #self.records
        if enter then
            self.report.synthetic_enter_acknowledgements = self.report.synthetic_enter_acknowledgements + 1
            return Json.encode({ succ = 1 }), 200, {}
        end
        error("progress preview dispatch disabled", 0)
    end
    function case:run(plugin, reader, pump, source_index, origin)
        local Source = require("weread.lib.position_source")
        local snapshot = assert(Source.document_metadata(reader.document, input.book_id, input.chapter_uid))
        assert(snapshot.record.format == "web_xhtml" and snapshot.record.raw_sha256 == input.source_raw_sha256)
        local function navigate(p)
            local bound = { basis = "filtered_xhtml_utf16", upload_verified = false, chapter_offset = p.chapter_offset }
            for _i, key in ipairs({ "book_id", "chapter_uid", "file_id", "book_version", "raw_sha256", "render_path" }) do
                bound[key] = snapshot.record[key]
            end
            local applied
            assert(plugin:openSourcePosition(bound, function(result) applied = result or false end))
            pump(function() return applied ~= nil end); assert(applied)
            local anchor = assert(source_index:locate(p.chapter_offset))
            assert(reader.document:isXPointerInCurrentPage(anchor.xpointer))
            local actual = assert(source_index:capture(anchor.xpointer))
            local retained = assert(plugin.progress_sync:current_source_target())
            assert(actual.co == p.chapter_offset and retained.chapter_offset == p.chapter_offset and retained.upload_verified == false)
            return source_index:capture(reader.document:getXPointer())
        end
        local unconfirmed = 0
        for index, p in ipairs({ baseline, target, baseline }) do
            local page_start = navigate(p)
            if index == 1 then
                local legacy = assert(plugin.progress_sync:capture_local())
                self.report.legacy_matches_source = legacy.chapter_offset == p.chapter_offset
                self.report.page_start_matches_source = page_start and page_start.co == p.chapter_offset or false
            end
            self.active = true
            local accepted, outcome = plugin.read_report:upload_position(input.book_id, {
                book_id = input.book_id, chapter_uid = p.chapter_uid, chapter_idx = p.chapter_idx,
                chapter_offset = p.chapter_offset, percent = p.raw_percent, summary = p.summary,
            }, 0)
            self.active = false
            assert(not accepted and outcome.error_kind == "unconfirmed" and outcome.report_attempted and not outcome.acknowledged)
            unconfirmed = unconfirmed + 1
        end
        self.report.source_points_verified, self.report.actual_upload_service = true, true
        self.report.all_reports_unconfirmed = unconfirmed == 3
        local restored
        assert(plugin:openSourcePosition(origin, function(result) restored = result or false end))
        pump(function() return restored ~= nil end); assert(restored)
        local anchor = assert(source_index:locate(origin.chapter_offset))
        assert(reader.document:isXPointerInCurrentPage(anchor.xpointer))
        local after = assert(source_index:capture(anchor.xpointer))
        assert(after.co == origin.chapter_offset)
        self.report.reader_position_restored = true
        self.report.source_upload_gate_preserved = origin.upload_verified == false
        assert(#self.records == 4 and self.report.synthetic_enter_acknowledgements == 1 and counters[30] == 0)
    end
    function case:finish(reason)
        self.report.denied_requests = tonumber(counters[30])
        self.report.failed_line = tonumber(type(reason) == "string" and reason:match("owner_progress_preview_case%.lua:(%d+):")) or 0
    end
    function case:private() return { records = self.records } end
    return case
end
