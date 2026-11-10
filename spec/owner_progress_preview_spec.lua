-- No dispatch callback exists. Only one synthetic enter acknowledgement and
-- three bounded, intercepted reports can be reached from production bodies.
package.path = "./?.lua;" .. package.path
local decoded, serial = {}, 0
package.loaded.json = { decode = function(value) if value == "[]" then return {} end; return assert(decoded[value]) end,
    encode = function(value) serial = serial + 1; local key = "synthetic-json-" .. serial; decoded[key] = value; return key end }
local Json, Protocol = require("json"), require("weread.lib.protocol")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function fixture()
    local baseline = { book_id = "900001", chapter_uid = "2", chapter_idx = 1, chapter_offset = 20, raw_percent = 25, summary = "synthetic" }
    local target = {}; for key, value in pairs(baseline) do target[key] = value end; target.chapter_offset = 21
    local input = { vid = "900000", book_id = "900001", chapter_uid = "2", source_format = "web_xhtml",
        progress_preview = { baseline = baseline, target = target } }
    local counters = require("ffi").new("int[1024]")
    local case = dofile("spec/koreader/owner_progress_preview_case.lua")(input,counters)
    local book = { psvts = "synthetic-session", pclts = "synthetic-client-time", token = "synthetic-token" }
    local client = { settings = { get = function() return { wr_vid = input.vid } end, get_book = function() return book end } }
    local function body(stage)
        local p = stage == "write_probe" and target or baseline
        local make = stage == "write_enter" and Protocol.make_enter_read_payload or Protocol.make_read_payload
        return make{ book_id = input.book_id, chapter_uid = p.chapter_uid, chapter_idx = p.chapter_idx,
            chapter_offset = p.chapter_offset, progress = p.raw_percent, summary = p.summary,
            psvts = book.psvts, pclts = book.pclts, token = book.token, elapsed_seconds = 0 }
    end
    local function request(stage)
        return { url = "https://weread.qq.com/web/book/read", method = "POST", sensitive = true,
            headers = { Referer = Protocol.reader_url(input.book_id) }, body = Json.encode(body(stage)) }
    end
    return { case = case, client = client, counters = counters, request = request, body = body }
end
local f = fixture()
expect(not pcall(f.case.request,f.case,f.client,f.request("write_enter")), "inactive preview acknowledged a request")
f = fixture(); f.case.active = true
local ack, code = f.case:request(f.client,f.request("write_enter"))
expect(code == 200 and Json.decode(ack).succ == 1, "one synthetic enter acknowledgement unavailable")
for _i, stage in ipairs({ "write_same", "write_probe", "write_restore" }) do
    expect(not pcall(f.case.request,f.case,f.client,f.request(stage)), "report escaped its dispatch barrier")
end
expect(#f.case:private().records == 4 and f.case.report.network_write_dispatches == 0, "private body capture incomplete")
expect(not pcall(f.case.request,f.case,f.client,f.request("write_restore")), "fifth request acknowledged")
for _i, change in ipairs({ function(r) r.method = "GET" end, function(r) r.sensitive = false end,
    function(r) r.headers.Cookie = "synthetic-cookie" end, function(r) r.headers.Authorization = "synthetic-bearer" end,
    function(r) r.headers.accessToken = "synthetic-native-access" end, function(r) r.skip_cookie = true end,
    function(r) r.sink = function() end end, function(r) r.body = Json.encode({}) end,
    function(r) r.headers.Referer = "https://other.example/" end }) do
    f = fixture(); f.case.active = true
    local request = f.request("write_enter"); change(request)
    expect(not pcall(f.case.request,f.case,f.client,request) and #f.case.records == 0, "mutated scope received synthetic acknowledgement")
end
for _i, change in ipairs({ function(b) b.co = 999 end, function(b) b.rt = 1 end, function(b) b.pr = 26 end,
    function(b) b.c = Protocol.e("3") end, function(b) b.b = Protocol.e("900002") end, function(b) b.ps = "foreign-session" end }) do
    f = fixture(); f.case.active = true
    f.case:request(f.client,f.request("write_enter"))
    local body = f.body("write_same"); change(body)
    local signed = {}; for key, value in pairs(body) do if key ~= "s" then signed[key] = value end end
    body.s = Protocol.sign(Protocol.sorted_query(signed))
    local request = f.request("write_same"); request.body = Json.encode(body)
    expect(not pcall(f.case.request,f.case,f.client,request) and #f.case.records == 1, "signed but out-of-scope report captured")
end
print("owner_progress_preview_spec: " .. checks .. " checks")
