-- Real native replies and credentials cross captured memory pipes only.
require("ffi").log = function() end
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({})
require("document/canvascontext"):init(require("device"))
package.path = assert(arg[1]) .. "/?.lua;" .. package.path
local Json = require("json")
local input = io.stdin:read(12 * 1024 * 1024 + 1)
local ok, result = pcall(function()
    assert(#input <= 12 * 1024 * 1024)
    local payload = Json.decode(input); input = nil
    assert(type(payload.samples) == "table" and #payload.samples >= 1 and #payload.samples <= 12)
    local Data = require("weread.lib.native_annotation_data")
    local Source = require("weread.lib.annotation_access")
    local scope = { vid = payload.native_credentials and payload.native_credentials.vid or "900000", epoch = 1 }
    local settings = { get = function(_self, _key, default) return default end,
        get_auth_scope = function() return scope end, auth_scope_matches = function(_self, value) return value == scope end }
    local client = require("weread.lib.client"):new(settings)
    local output = { model = Json.decode("[]") }
    for _i, sample in ipairs(payload.samples) do
        output.model[#output.model + 1] = Data.project(client, sample.kind, sample.source, sample.book_id, sample.chapter_uid, sample.requested)
    end
    if not payload.native_credentials then return output end
    local store = { read = function() return payload.native_credentials, 1 end }
    local selected = assert(Source.capture(settings, store))
    local request, requests, active = client.request, 0
    local function equal(first, second)
        if type(first) ~= type(second) then return false end
        if type(first) ~= "table" then return first == second end
        for key, value in pairs(first) do if not equal(value, second[key]) then return false end end
        for key in pairs(second) do if first[key] == nil then return false end end
        return true
    end
    function client:request(options)
        assert(active and options.skip_cookie and options.persist_response_cookies == false and options.sensitive)
        assert(options.headers.accessToken == payload.native_credentials.accessToken and options.headers.vid == scope.vid)
        assert(not options.headers.Cookie and not options.headers.Authorization)
        if active.kind == "underlines" then
            assert(options.method == "GET" and not options.body and options.url == "https://i.weread.qq.com/book/underlines?bookId="
                .. active.book_id .. "&chapterUid=" .. active.chapter_uid .. "&synckey=0")
        else
            assert(options.method == "POST" and options.url == "https://i.weread.qq.com/book/readreviews")
            assert(equal(self:json_decode(options.body), { bookId = active.book_id, chapterUid = tonumber(active.chapter_uid),
                cht2sMode = "", reviews = active.requested }))
        end
        requests = requests + 1; assert(requests <= #payload.samples)
        return request(self, options)
    end
    output.native = Json.decode("[]")
    for _i, sample in ipairs(payload.samples) do
        active = sample
        local success, value
        if sample.kind == "underlines" then success, value = client:get_chapter_underlines(sample.book_id, sample.chapter_uid, selected)
        else success, value = client:get_chapter_reviews_batch(sample.book_id, sample.chapter_uid, sample.requested, selected) end
        assert(success and value._source_kind == "native")
        value._source_kind = nil
        output.native[#output.native + 1] = value
    end
    output.requests = requests
    return output
end)
io.stdout:write("\nWEREAD_NATIVE_ANNOTATIONS_RESULT=" .. Json.encode(ok and result or { error = "probe_failed" }) .. "\n")
os.exit(ok and 0 or 1)
