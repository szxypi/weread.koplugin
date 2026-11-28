package.path = "./?.lua;./?/init.lua;" .. package.path
local Data = require("weread.lib.native_annotation_data")
local Source = require("weread.lib.annotation_access")
local Auth = require("weread.lib.native_authorization")
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local null, array_mt = function() end, {}
local function array(value) return setmetatable(value or {}, array_mt) end
local function fixture()
    local scope, revision, current, native, key = { vid = "900000", epoch = 1 }, 1, true, true, ""
    local credentials = { vid = "900000", accessToken = "synthetic-native", refreshToken = "synthetic-refresh", deviceId = string.rep("1", 32) }
    local status, callback, encoded = 200, nil, nil
    local source = { underlines = array({ { range = "12-45", count = 3, score = 0.5, type = 0, metadata = null } }) }
    local settings = { get = function(_self, name, default) if name == "api_key" then return key end return default end,
        get_auth_scope = function() return scope end, auth_scope_matches = function(_self, value) return current and value == scope end }
    local store = { read = function() return native and credentials or nil, revision end }
    local requests, gateways = {}, 0
    local client = { settings = settings, json_encode = function(_self, value) encoded = value; return "encoded" end,
        json_decode = function(_self, value) if value == "null" then return null elseif value == "[]" then return array() end return source end,
        request = function(_self, options)
            requests[#requests + 1] = options
            if callback then callback() end
            if status == "transport" then error("private diagnostic") end
            return "reply", status
        end,
        gateway = function(_self, endpoint, params)
            expect(endpoint == "/book/underlines" and params.bookId ~= nil, "gateway contract retained")
            gateways = gateways + 1
            return source
        end }
    return { source = source, client = client, store = store, settings = settings, requests = requests,
        selected = function() return Source.capture(settings, store) end,
        gateway_count = function() return gateways end, encoded = function() return encoded end,
        change = function(values)
            if values.status then status = values.status end
            if values.revision then revision = values.revision end
            if values.current ~= nil then current = values.current end
            if values.native ~= nil then native = values.native end
            if values.key ~= nil then key = values.key end
            if values.callback then callback = values.callback end
        end }
end
local f = fixture()
local selected = f.selected()
local result = Source.fetch(f.client, "underlines", "900001", 2, nil, selected)
expect(result._source_kind == "native" and #result.underlines == 1, "native-only access works without Skill key")
expect(result.underlines[1].metadata == null and f.gateway_count() == 0, "opaque null metadata survives")
local request = f.requests[1]
expect(request.method == "GET" and request.url == "https://i.weread.qq.com/book/underlines?bookId=900001&chapterUid=2&synckey=0", "fixed native underline request")
expect(request.sensitive and request.skip_cookie and request.persist_response_cookies == false and not request.headers.Cookie
    and not request.headers.Authorization and request.headers.accessToken == "synthetic-native", "native credentials stay isolated")
local batch = array({ { range = "12-45", maxIdx = 0, count = 30, synckey = 0 } })
f.source.underlines = nil
f.source.reviews = array({ { range = "12-45", pageReviews = array({ { review = { bookId = "900001", chapterUid = 2,
    content = "Synthetic thought", abstract = "Synthetic quote", range = "12-45" } } }) } })
result = Source.fetch(f.client, "thoughts", "900001", "2", batch, selected)
expect(result._source_kind == "native" and #result.reviews[1].pageReviews == 1, "native thought projection")
expect(f.requests[2].method == "POST" and f.requests[2].url == "https://i.weread.qq.com/book/readreviews"
    and f.encoded().bookId == "900001" and f.encoded().chapterUid == 2 and f.encoded().cht2sMode == ""
    and f.encoded().reviews == batch, "read-only thought POST contract")
for _, values in ipairs({ { status = 401 }, { status = 403 }, { status = 429 }, { status = 500 }, { status = "transport" } }) do
    f = fixture(); f.change { key = "synthetic-key" }; f.change(values)
    local ok, err = pcall(Source.fetch, f.client, "underlines", "900001", 2, nil, Source.pin(f.selected(), "native", "900001"))
    expect(not ok and f.gateway_count() == 0 and not tostring(err):find("private", 1, true), "native failure never changes route or leaks diagnostics")
    expect(Source.terminal(err) == (values.status ~= 500 and values.status ~= "transport"), "terminal failures do not get three retries")
end
for _, status in ipairs({ 401, 403, 503, "transport" }) do
    f = fixture(); f.change { status = status, key = "synthetic-key" }
    local value = Source.fetch(f.client, "underlines", "900001", 2, nil, f.selected())
    expect(value._source_kind == "gateway" and f.gateway_count() == 1 and #f.requests == 1, "fresh underline failure can select configured gateway before any native data commits")
end
f = fixture(); f.change { status = 429, key = "synthetic-key" }
expect(not pcall(Source.fetch, f.client, "underlines", "900001", 2, nil, f.selected()) and f.gateway_count() == 0,
    "fresh rate failure never changes channel")
local pinned = Source.pin(f.selected(), "native", "900001")
expect(not pcall(Source.pin, pinned, "gateway", "900001"), "chosen job channel cannot be rebound")
for _, values in ipairs({ { revision = 2 }, { current = false }, { native = false }, { key = "new-key" } }) do
    f = fixture(); selected = f.selected(); f.change(values)
    expect(not Source.matches(f.settings, selected), "changed grant invalidates snapshot")
    expect(not pcall(Source.fetch, f.client, "underlines", "900001", 2, nil, selected) and #f.requests == 0, "stale grant sends nothing")
end
f = fixture(); selected = f.selected(); f.change { callback = function() f.change { revision = 2 } end }
expect(not pcall(Source.fetch, f.client, "underlines", "900001", 2, nil, selected), "grant change during HTTP discards reply")
f = fixture(); f.change { native = false, key = "synthetic-key" }
expect(Source.fetch(f.client, "underlines", "900001", 2, nil, f.selected())._source_kind == "gateway" and #f.requests == 0, "gateway-only fallback retained")
f = fixture(); f.change { key = "synthetic-key" }
expect(Source.fetch(f.client, "underlines", "MP_WXS_synthetic", 2, nil, f.selected())._source_kind == "gateway", "non-native identities retain gateway route")
expect(Source.kind(f.selected(), "MP_WXS_synthetic") == "gateway", "resume route matches actual non-native request")
f = fixture(); f.change { native = false }
expect(not f.selected(), "no native credential derived from Web cookies")
for _, value in ipairs({ "0", "1-1", "5-2", "1-2147483648", "x", false, 3 }) do
    expect(not pcall(Data.range, value), "invalid underline range rejected")
end
f = fixture()
for _, source in ipairs({ {}, { underlines = {} }, { underlines = array({ false }) },
    { underlines = array(), bookId = "900002" }, { underlines = array(), chapterUid = 3 },
    { underlines = array(), errcode = false }, { underlines = array(), succ = false },
    { underlines = array({ { range = "1-2", score = math.huge } }) },
    { underlines = array({ { range = "1-2" }, { range = "1-2" } }) } }) do
    expect(not pcall(Data.project, f.client, "underlines", source, "900001", "2"), "malformed or wrong-scope data rejected")
end
expect(#Data.project(f.client, "underlines", { underlines = array() }, "900001", "2").underlines == 0, "valid empty response retained")
local auth = Auth:new(f.client, { expected_vid = "900000" })
for _, args in ipairs({ { "underlines", "900001", 0 }, { "underlines", "900001", "2&extra=1" },
    { "underlines", "MP_WXS_test", 2 }, { "write", "900001", 2 }, { "thoughts", "900001", 2, array() } }) do
    expect(not pcall(auth.read_annotations, auth, { vid = "900000", accessToken = "synthetic" }, unpack(args)), "invalid native input sends nothing")
end
expect(not pcall(auth.read_annotations, auth, { vid = "900002", accessToken = "synthetic" }, "underlines", "900001", 2)
    and #f.requests == 0, "wrong owner sends no HTTP")
print("native_annotations_spec: " .. checks .. " checks")
