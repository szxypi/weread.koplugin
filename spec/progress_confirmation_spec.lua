-- Single-dispatch progress writes and bounded, exact readback receipts.
package.path = "./?.lua;" .. package.path
package.preload["weread.lib.content"] = function() return {} end
local ReadReport = require("weread.lib.read_report")
local Model = require("weread.lib.progress_readback")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function position() return { book_id = "900001", chapter_uid = 2, chapter_idx = 1, chapter_offset = 15, percent = 25 } end
local function raw(offset) return { bookId = "900001", chapterUid = 2, chapterIdx = 1, chapterOffset = offset or 15, progress = 25.7 } end
local function fixture(options)
    options = options or {}
    local f = { writes = {}, reads = 0, contexts = 0, renewals = 0, cookies = { wr_vid = "900001" } }
    local values = { books = {}, cookies = f.cookies }
    local settings = {
        get = function(_self, key, default) return values[key] or default end,
        set = function(_self, key, value) values[key] = value end,
        flush = function() end,
    }
    local client = {
        report_read = function(_self, body, _referer, request_options)
            expect(request_options and request_options.sensitive == true, "private write diagnostics not bounded")
            f.writes[#f.writes + 1] = body
            if options.write then return options.write(f, body) end
            return { succ = 1 }, 200
        end,
        get_web_progress = function(_self, key, request_options)
            expect(request_options and request_options.sensitive == true, "private readback diagnostics not bounded")
            expect(key == "900001", "read escaped selected book")
            f.reads = f.reads + 1
            return options.read and options.read(f) or raw()
        end,
        renew_cookie = function() f.renewals = f.renewals + 1; error("unexpected renewal") end,
    }
    f.report = ReadReport:new{ settings = settings, client = client,
        scheduler = { scheduleIn = function() end, unschedule = function() end },
        get_document = function() end, detect_book = function() return "900001" end,
        subprocess = false, now = function() return 100 end }
    f.report.ensure_context = function(self, key, force)
        expect(key == "900001" and not force, "unexpected context refresh")
        f.contexts = f.contexts + 1
        return { book_id = key, psvts = "synthetic-session", pclts = "synthetic-client-time", read_session_id = self.session_id }
    end
    f.report._run_pipeline = function() error("periodic retry pipeline used for position") end
    return f
end

do
    local f = fixture()
    local ok, result = f.report:upload_position("900001", position(), 0)
    expect(ok and result.acknowledged and result.position_confirmed, "matching acknowledged upload not confirmed")
    expect(result.remote.raw_percent == 25.7 and result.remote.chapter_offset == 15, "server metadata lost")
    expect(#f.writes == 2 and f.reads == 1 and f.contexts == 1 and f.renewals == 0, "normal write sequence changed")
    expect(f.writes[1].rt == nil and f.writes[2].rt == 0, "position upload includes reading time")
end
for _i, failure in ipairs({ "empty", "rejected", "status", "transport", "conflict", "synckey" }) do
    local f = fixture{ write = function(state)
        if #state.writes == 1 then return { succ = 1 }, 200 end
        if failure == "transport" then error("synthetic-private-body") end
        if failure == "empty" then return {}, 200 end
        if failure == "rejected" then return { errCode = -2012 }, 200 end
        if failure == "status" then return { succ = 1 }, 401 end
        if failure == "conflict" then return { succ = 1, errCode = -1 }, 200 end
        return { synckey = 100 }, 200
    end }
    local ok, result = f.report:upload_position("900001", position(), 0)
    expect(not ok and result.error_kind == "unconfirmed" and not result.acknowledged, "uncertain write was accepted")
    expect(#f.writes == 2 and f.reads == 0 and f.contexts == 1 and f.renewals == 0, "uncertain write replayed or renewed")
    expect(result.report_attempted and not result.error:find("synthetic%-private"), "private transport detail escaped")
end
for _i, throwing in ipairs({ false, true }) do
    local f = fixture{ write = function() if throwing then error("unknown enter") end; return {}, 200 end }
    local ok, result = f.report:upload_position("900001", position(), 0)
    expect(not ok and result.enter_attempted and not result.report_attempted, "unconfirmed enter did not stop")
    expect(#f.writes == 1 and f.reads == 0 and f.renewals == 0, "unconfirmed enter continued sending")
end
do
    local f = fixture{ read = function(state) return raw(state.reads < 3 and 14 or 15) end }
    local ok, result = f.report:upload_position("900001", position(), 0)
    local receipt = result.confirmation
    expect(not ok and result.acknowledged and receipt and next(receipt) == nil, "receipt exposes private state or is absent")
    ok, result = f.report:confirm_position(receipt)
    expect(not ok and result.confirmation_reads == 2, "second read unexpectedly accepted")
    ok, result = f.report:confirm_position(receipt)
    expect(ok and result.position_confirmed and result.confirmation_reads == 3, "delayed coordinate not confirmed")
    expect(not f.report:confirm_position(receipt) and f.reads == 3 and #f.writes == 2, "used receipt replayed")
end
do
    local f = fixture{ read = function() return raw(14) end }
    local _ok, result = f.report:upload_position("900001", position(), 0)
    expect(not _ok, "stale read accepted")
    local receipt = result.confirmation
    f.report:confirm_position(receipt)
    local ok, final = f.report:confirm_position(receipt)
    expect(not ok and final.error_kind == "unconfirmed" and not final.confirmation, "read limit not final")
    expect(not f.report:confirm_position(receipt) and not f.report:confirm_position({}) and f.reads == 3, "read bound bypassed")
end
do
    local f = fixture{ read = function() return raw(14) end }
    local _ok, result = f.report:upload_position("900001", position(), 0)
    expect(not _ok, "stale read accepted")
    f.cookies.wr_skey = "synthetic-replacement"
    expect(not f.report:confirm_position(result.confirmation) and f.reads == 1, "changed authorization performed stale read")
end
for _i, change in ipairs({ { basis = "filtered_xhtml_utf16" }, { upload_verified = false }, { chapter_idx = -1 },
    { chapter_offset = 1.5 }, { percent = 0 / 0 }, { book_id = "900002" } }) do
    local f, p = fixture(), position()
    for key, value in pairs(change) do p[key] = value end
    expect(not f.report:upload_position("900001", p, 0), "invalid/read-only target accepted")
    expect(#f.writes == 0 and f.contexts == 0 and f.reads == 0, "invalid target reached transport")
end
do
    local f, p = fixture(), position()
    p.source_position = { chapter_offset = 12345, basis = "filtered_xhtml_utf16", upload_verified = false }
    expect(f.report:upload_position("900001", p, 0), "nested read-only snapshot blocked ordinary progress")
    expect(f.writes[2].co == 15, "read-only source units entered wire payload")
    local g = fixture()
    expect(not g.report:upload_position("900001", position(), 1) and #g.writes == 0, "nonzero time accepted by position path")
    g.report.job = {}
    local ok, result = g.report:upload_position("900001", position(), 0)
    expect(not ok and result.error_kind == "busy" and #g.writes == 0, "time reporter ownership bypassed")
end
do
    local p, q = position(), position()
    expect(Model.same_intent(p, q), "equal intent rejected")
    q.chapter_offset = q.chapter_offset + 1
    expect(not Model.same_intent(p, q), "adjacent intent cleared by tolerance")
    q = position(); q.source_position = { chapter_offset = 99 }
    expect(not Model.same_intent(p, q), "new source intent cleared")
end
do
    local target = assert(Model.expected("900001", position()))
    for _i, field in ipairs({ "chapterUid", "chapterIdx", "chapterOffset" }) do
        local response = raw(); response[field] = nil
        expect(not Model.check(response, target).matches, "missing coordinate defaulted to zero")
    end
    local response = raw(); response.chapter_uid = 3
    expect(not Model.check(response, target).matches, "conflicting chapter aliases accepted")
    response = raw(); response.progress = 100.1
    expect(not Model.check(response, target).matches, "invalid server metadata ignored")
    local f = fixture{ read = function(state) state.cookies.wr_skey = "synthetic-rotation"; return raw() end }
    local ok, result = f.report:upload_position("900001", position(), 0)
    expect(not ok and result.error_kind == "unconfirmed", "authorization change during read accepted")
    expect(f.reads == 1 and #f.writes == 2, "authorization change caused another request")
end
print("progress_confirmation_spec: " .. checks .. " checks")
