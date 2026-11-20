package.path = "./?.lua;" .. package.path
local body
local Store = {}
package.loaded["weread.lib.native_credentials"] = Store
package.loaded.json = { decode = function() return body end, util = { null = function() end } }
local checks = 0
local function expect(value) checks = checks + 1; assert(value) end
local function fixture(mode)
    local input = { vid = "900000", book_id = "900001", chapter_uid = "2", shelf_books = 1,
        annotations = { credentials = { vid = "900000", accessToken = "synthetic-only",
            refreshToken = "synthetic-refresh", deviceId = string.rep("1", 32) },
            ranges = {}, digest = string.rep("a", 64), underlines = 31, thought_items = 3 } }
    for index = 1, 31 do input.annotations.ranges[index] = index .. "-" .. (index + 1) end
    local counters = setmetatable({}, { __index = function() return 0 end })
    local case = dofile("spec/koreader/owner_annotations_case.lua")(input, mode or "live", counters)
    local dispatched = 0
    local function dispatch() dispatched = dispatched + 1; return "synthetic", 200 end
    local request = { url = "https://i.weread.qq.com/book/underlines?bookId=900001&chapterUid=2&synckey=0", method = "GET",
        skip_cookie = true, persist_response_cookies = false, sensitive = true,
        headers = { vid = input.vid, accessToken = input.annotations.credentials.accessToken } }
    return case, counters, request, dispatch, function() return dispatched end
end
local case, counters, request, dispatch, count = fixture()
expect(not pcall(case.request, case, {}, request, dispatch) and count() == 0 and counters[22] == 1)
case.enabled = true
expect(case:request({}, request, dispatch) == "synthetic" and count() == 1)
expect(not pcall(case.request, case, {}, request, dispatch) and count() == 1)
request.url, request.method, request.body = "https://i.weread.qq.com/book/readreviews", "POST", "synthetic-json"
body = { bookId = "900001", chapterUid = 2, cht2sMode = "", reviews = {} }
for index = 1, 30 do body.reviews[index] = { range = index .. "-" .. (index + 1), maxIdx = 0, count = 30, synckey = 0 } end
expect(case:request({}, request, dispatch) == "synthetic" and count() == 2)
expect(not pcall(case.request, case, {}, request, dispatch) and count() == 2)
body.reviews = { { range = "31-32", maxIdx = 0, count = 30, synckey = 0 } }
expect(case:request({}, request, dispatch) == "synthetic" and count() == 3)
expect(not pcall(case.request, case, {}, request, dispatch) and count() == 3)
case:finish()
expect(case.report.native_underlines_requests == 1 and case.report.native_thought_requests == 2)
for _i, change in ipairs({ function(r) r.method = "POST"; r.body = "{}" end,
    function(r) r.url = "https://i.weread.qq.com/login" end,
    function(r) r.url = "https://i.weread.qq.com/book/read" end,
    function(r) r.url = r.url .. "&extra=1" end,
    function(r) r.headers.Cookie = "synthetic-cookie" end,
    function(r) r.headers.Authorization = "synthetic-bearer" end,
    function(r) r.headers.accessToken = "different" end,
    function(r) r.headers.vid = "900099" end,
    function(r) r.skip_cookie = false end,
    function(r) r.persist_response_cookies = true end,
    function(r) r.sensitive = false end }) do
    case, counters, request, dispatch, count = fixture(); case.enabled = true; change(request)
    expect(not pcall(case.request, case, {}, request, dispatch) and count() == 0 and counters[22] == 1)
end
case, counters, request, dispatch, count = fixture("reopen"); case.enabled = true
expect(not pcall(case.request, case, {}, request, dispatch) and count() == 0 and counters[22] == 1)
expect(not pcall(Store._write))
print("owner_annotation_probe_spec: " .. checks .. " checks")
