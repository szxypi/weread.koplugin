-- Actual dispatch is possible only with an installed, armed scope; every
-- attempt consumes one of four slots before the transport can become unknown.
package.path = "./?.lua;" .. package.path
local decoded, serial = {}, 0
package.loaded.json = { decode = function(value) if value == "[]" then return {} end; return assert(decoded[value]) end,
    encode = function(value) serial = serial + 1; local key = "synthetic-json-" .. serial; decoded[key] = value; return key end }
local Json, Protocol = require("json"), require("weread.lib.protocol")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function fixture(permit)
    local baseline = { book_id = "900001", chapter_uid = "2", chapter_idx = 1, chapter_offset = 20, raw_percent = 25, summary = "synthetic" }
    local target = {}; for key, value in pairs(baseline) do target[key] = value end; target.chapter_offset = 21
    local input = { vid = "900000", book_id = "900001", chapter_uid = "2", source_format = "web_xhtml",
        progress_roundtrip = { baseline = baseline, target = target, permit_writes = permit ~= false,
            intent_digest = permit == false and "" or string.rep("a",64) } }
    local counters = require("ffi").new("int[1024]")
    local case = dofile("spec/koreader/owner_progress_roundtrip_case.lua")(input,counters)
    local f = { case = case, input = input, counters = counters, valid = true, sends = 0, cloud = 20 }
    local book = { psvts = "synthetic-session", pclts = "synthetic-client-time", token = "synthetic-token" }
    case.current = function() return f.valid end
    f.client = { settings = { get = function() return { wr_vid = input.vid } end, get_book = function() return book end },
        get_web_progress = function(_self, key, options)
            expect(key == input.book_id and options.sensitive, "unguarded observation")
            if f.after_read then f.after_read() end
            return { bookId = input.book_id, chapterUid = 2, chapterIdx = 1, chapterOffset = f.cloud, progress = 25 }
        end }
    function f.request(stage)
        local p = stage == "write_probe" and target or baseline
        local make = stage == "write_enter" and Protocol.make_enter_read_payload or Protocol.make_read_payload
        local body = make{ book_id = input.book_id, chapter_uid = p.chapter_uid, chapter_idx = p.chapter_idx,
            chapter_offset = p.chapter_offset, progress = p.raw_percent, summary = p.summary,
            psvts = book.psvts, pclts = book.pclts, token = book.token, elapsed_seconds = 0 }
        return { url = "https://weread.qq.com/web/book/read", method = "POST", sensitive = true,
            headers = { Referer = Protocol.reader_url(input.book_id) }, body = Json.encode(body) }
    end
    function f.dispatch(_client, options)
        f.sends = f.sends + 1
        f.cloud = Json.decode(options.body).co
        if f.throwing then error("synthetic-private-transport") end
        return Json.encode({ succ = 1 }),200,{}
    end
    return f
end
local f = fixture(); f.case.active = true
expect(not pcall(f.case.request,f.case,f.client,f.request("write_enter"),f.dispatch) and f.sends == 0,
    "uninstalled guard sent a request")
f = fixture(); f.case:install_guard()
expect(not pcall(f.case.request,f.case,f.client,f.request("write_enter"),f.dispatch) and f.sends == 0,
    "inactive experiment sent a request")
f = fixture(); f.case:install_guard(); f.case.active = true
for _i, stage in ipairs({ "write_enter", "write_same", "write_probe", "write_restore" }) do
    local _, code = f.case:request(f.client,f.request(stage),f.dispatch)
    expect(code == 200,"actual response was replaced")
end
f.case:finish()
expect(f.sends == 4 and f.counters[31] == 4 and f.cloud == 20,"four-stage dispatch did not restore original coordinate")
expect(f.case.report.synthetic_acknowledgements == 0 and #f.case:private().records == 4,"experiment manufactured acknowledgement")
expect(not pcall(f.case.request,f.case,f.client,f.request("write_restore"),f.dispatch) and f.sends == 4,"fifth POST dispatched")
f = fixture(); f.case:install_guard(); f.case.active = true
f.case:request(f.client,f.request("write_enter"),f.dispatch)
f.case:request(f.client,f.request("write_same"),f.dispatch)
f.cloud = 99
expect(not pcall(f.case.request,f.case,f.client,f.request("write_probe"),f.dispatch) and f.sends == 2,
    "changed external coordinate was overwritten")
expect(f.case.report.unrelated_position_seen,"changed coordinate was not reported")
f = fixture(); f.case:install_guard(); f.case.active = true
f.case:request(f.client,f.request("write_enter"),f.dispatch)
f.case:request(f.client,f.request("write_same"),f.dispatch)
f.throwing = true
expect(not pcall(f.case.request,f.case,f.client,f.request("write_probe"),f.dispatch) and f.counters[31] == 3,
    "unknown send did not consume its slot")
expect(not pcall(f.case.request,f.case,f.client,f.request("write_probe"),f.dispatch) and f.sends == 3,
    "uncertain probe was replayed")
f.throwing = false
f.case:request(f.client,f.request("write_restore"),f.dispatch)
expect(f.sends == 4 and f.cloud == 20,"conditional restore lost the remaining slot")
f = fixture(); f.case:install_guard(); f.case.active = true
f.after_read = function() f.valid = false end
expect(not pcall(f.case.request,f.case,f.client,f.request("write_enter"),f.dispatch) and f.sends == 0,
    "session change during observation sent a request")
local clock = os.time
local now = clock()
rawset(os,"time",function() return now end)
f = fixture(); f.case:install_guard(); f.case.active = true
local request = f.request("write_enter")
f.after_read = function() now = now + 31 end
expect(not pcall(f.case.request,f.case,f.client,request,f.dispatch) and f.sends == 0,"slow precheck sent an expired body")
rawset(os,"time",clock)
f = fixture(false); f.case:install_guard(); f.case.active = true
expect(not pcall(f.case.request,f.case,f.client,f.request("write_enter"),f.dispatch) and f.sends == 0,
    "disarmed executor reached transport")
expect(f.case.report.permission_blocked and f.counters[31] == 0,"disarmed boundary was not recorded")
print("owner_progress_roundtrip_spec: " .. checks .. " checks")
