package.path = "./?.lua;./?/init.lua;" .. package.path
local Source = require("weread.lib.shelf_source")
local checks = 0
local function expect(value, label) checks = checks + 1 assert(value, label) end
local function fixture(mode)
    local data = { books = {{ bookId = 123, title = "Native book", author = "Author", version = 700,
        bookVersion = 999, cover = "https://example.invalid/cover", readUpdateTime = "10", finishReading = 1,
        unknown_secret = "private-response" }}, archive = {{ archiveId = 5, name = "Group", bookIds = { 123 } }} }
    local current, revision, present, native_fail, web_fail, on_request = true, 1, true, false, false, nil
    local config, requests, web_calls = { source = mode or "auto" }, {}, 0
    local cookies, api_key, cookie_calls, cookie_fail, cookie_callback = {}, "test-key", 0, false, nil
    local credentials = { vid = "123", accessToken = "test-native-access", refreshToken = "test-native-refresh",
        deviceId = string.rep("1", 32) }
    local scope = { vid = "123", epoch = 1 }
    local settings = { data_dir = "/unused", get = function(_self, key)
        if key == "shelf" then return config elseif key == "api_key" then return api_key elseif key == "cookies" then return cookies end
    end, get_auth_scope = function() return scope end,
        auth_scope_matches = function(_self, candidate) return current and candidate == scope end }
    local store = { read = function() return present and credentials or nil, revision end }
    local client = { settings = settings,
        request = function(_self, request)
            requests[#requests + 1] = request
            if on_request then on_request() end
            if native_fail then error("private-url-with-token", 0) end
            return "fixture", 200
        end,
        json_decode = function() return data end,
        get_gateway_shelf = function()
            web_calls = web_calls + 1
            if web_fail then error("gateway fixture failure", 0) end
            return { books = {{ bookId = "web", title = "Gateway book" }}, archive = {} }, 200, {}
        end,
        get_web_shelf = function(_self, snapshot)
            cookie_calls = cookie_calls + 1
            expect(snapshot.wr_vid == "123" and snapshot.wr_skey == "synthetic-web-access", "Web jar was not account-bound")
            if cookie_callback then cookie_callback() end
            if cookie_fail then error("private-web-response-with-cookie", 0) end
            return data
        end,
    }
    return { client = client, settings = settings, store = store, requests = requests, data = data,
        fetch = function(options) options = options or {} options.store = store return Source.fetch(client, options) end,
        counts = function() return #requests, web_calls, cookie_calls end,
        change = function(options)
            if options.mode then config.source = options.mode end
            if options.current ~= nil then current = options.current end
            if options.revision then revision = options.revision end
            if options.present ~= nil then present = options.present end
            if options.native_fail ~= nil then native_fail = options.native_fail end
            if options.web_fail ~= nil then web_fail = options.web_fail end
            if options.on_request then on_request = options.on_request end
            if options.cookies then cookies = options.cookies end
            if options.api_key ~= nil then api_key = options.api_key end
            if options.cookie_fail ~= nil then cookie_fail = options.cookie_fail end
            if options.cookie_callback then cookie_callback = options.cookie_callback end
        end }
end
local f = fixture()
local result = f.fetch()
expect(result._shelf_source == "native" and result._native_revision == 1, "automatic prefers verified native grant")
expect(result.books[1].bookId == "123" and result.archive[1].bookIds[1] == "123", "IDs canonicalized for groups")
expect(result.books[1]._native_version == 700 and result.books[1].bookVersion == nil and result.books[1].version == nil,
    "unverified native version cannot become a Web download version")
expect(result.books[1].unknown_secret == nil and result.books[1].readUpdateTime == 10, "bounded display metadata normalized")
expect(f.data.books[1].bookId == 123 and f.data.books[1].bookVersion == 999, "source snapshot not mutated")
local request = f.requests[1]
expect(request.url == "https://i.weread.qq.com/shelf/sync" and request.method == "GET" and request.body == nil,
    "native source sends only previously verified read endpoint")
expect(request.sensitive and request.skip_cookie and request.persist_response_cookies == false
    and request.headers.accessToken == "test-native-access" and request.headers.Cookie == nil
    and request.headers.Authorization == nil, "native request isolated and diagnostics redacted")
local _, web = f.counts()
expect(web == 0, "successful native source does not also fetch gateway")
f = fixture("gateway"); result = f.fetch()
local native
native, web = f.counts()
expect(result._shelf_source == "gateway" and native == 0 and web == 1, "explicit standard skips native auth entirely")
f = fixture(); f.change({ native_fail = true }); result = f.fetch()
native, web = f.counts()
expect(result._shelf_source == "gateway" and result._native_fallback and native == 1 and web == 1,
    "automatic failure falls back exactly once with public indication")
f = fixture("native"); f.change({ native_fail = true })
local ok, err = pcall(f.fetch)
_, web = f.counts()
expect(not ok and err == "shelf_source/native_unavailable" and web == 0, "native-only failure cannot switch source")
f = fixture("native"); f.change({ present = false })
ok, err = pcall(f.fetch)
native, web = f.counts()
expect(not ok and err == "shelf_source/native_required" and native == 0 and web == 0, "native-only requires authorization")
local ready, reason = Source.ready(f.settings, f.store)
expect(not ready and reason == "native_required", "UI receives native authorization requirement")
f = fixture(); f.change({ present = false }); result = f.fetch()
native, web = f.counts()
expect(native == 0 and web == 1 and not result._native_fallback and result._native_revision == nil,
    "unconfigured automatic uses established gateway without a native revision guard")
for _i, change in ipairs({ { current = false }, { revision = 2 }, { mode = "gateway" }, { present = false } }) do
    f = fixture()
    f.change({ on_request = function() f.change(change) end })
    ok, err = pcall(f.fetch)
    _, web = f.counts()
    expect(not ok and err == "shelf_source/session_changed" and web == 0, "changed owner/grant/source stops without fallback")
end
f = fixture(); f.change({ current = false })
ok = pcall(function() f.fetch({ is_current = function() return false end }) end)
native, web = f.counts()
expect(not ok and native == 0 and web == 0, "stale queued refresh dispatches no HTTP")
f = fixture()
f.settings.get_auth_scope = function(_self, from_disk) return from_disk and { vid = "456", epoch = 2 } or nil end
ok, err = pcall(f.fetch)
native, web = f.counts()
expect(not ok and err == "shelf_source/session_changed" and native == 0 and web == 0,
    "missing local owner cannot bypass a different identified on-disk login")
expect(not Source.ready(f.settings, f.store), "inconsistent owner requires a new login before shelf access")
for _i, mutate in ipairs({
    function(data) data.books = nil end,
    function(data) data.books[2] = data.books[1] end,
    function(data) data.books[1].bookId = "" end,
    function(data) data.archive[1].bookIds = "invalid" end,
    function(data) data.books.extra = {} end,
}) do
    f = fixture(); mutate(f.data)
    result = f.fetch()
    expect(result._native_fallback and result.books[1].bookId == "web", "invalid native snapshot cannot replace cache with partial books")
end
f = fixture("native"); f.data.books, f.data.archive = {}, {}
result = f.fetch()
expect(#result.books == 0 and #result.archive == 0 and result._shelf_source == "native", "valid empty shelf remains empty")
f = fixture()
local original_request = f.client.request
f.client.request = function(self, options) original_request(self, options) return "fixture", 401 end
ok, err = pcall(f.fetch, { recover_auth = true })
_, web = f.counts()
expect(not ok and err == "shelf_source/native_expired" and web == 0, "401 recovery signal precedes gateway fallback")
local original_read = f.store.read
f.store.read = function() local value, current_revision = original_read() return value, current_revision, nil, true end
result = f.fetch({ recover_auth = true })
expect(result._shelf_source == "gateway" and result._native_fallback, "pending renewal cannot trigger automatic replay")
f = fixture(); result = f.fetch({ skip_native = true })
native, web = f.counts()
expect(native == 0 and web == 1 and result._native_fallback, "failed renewal can fall back without a second native attempt")
f = fixture("native"); result = f.fetch({ skip_native = true })
expect(result._shelf_source == "native", "native-only policy cannot be bypassed by fallback options")

local jar = {wr_vid="123",wr_skey="synthetic-web-access"}
f=fixture();f.change{present=false,api_key="",cookies=jar}
expect(Source.ready(f.settings,f.store),"verified Web account without key cannot read shelf")
result=f.fetch()
local cookie_calls
native,web,cookie_calls=f.counts()
expect(native==0 and web==0 and cookie_calls==1 and result._shelf_source=='web',"keyless automatic route contacted another source")
expect(result.books[1]._web_shelf_version==700 and result.books[1]._native_version==nil
    and result.books[1].bookVersion==nil and result.books[1].version==nil,"Web shelf version promoted to a download version")
expect(type(result._web_revision)=='string' and #result._web_revision==64,"Web result lacks revision for parent guard")
f=fixture('gateway');f.change{api_key='',cookies=jar}
result=f.fetch();native,web,cookie_calls=f.counts()
expect(native==0 and web==0 and cookie_calls==1 and result._shelf_source=='web',"standard policy cannot use verified Web login without key")
f=fixture();f.change{present=false,web_fail=true,cookies=jar}
result=f.fetch();native,web,cookie_calls=f.counts()
expect(native==0 and web==1 and cookie_calls==1 and result._gateway_fallback and result._shelf_source=='web',"gateway failure did not fall back exactly once")
f=fixture();f.change{native_fail=true,api_key='',cookies=jar}
result=f.fetch();native,web,cookie_calls=f.counts()
expect(native==1 and web==0 and cookie_calls==1 and result._native_fallback,"native failure cannot fall back to keyless Web")
f=fixture('native');f.change{native_fail=true,api_key='',cookies=jar}
ok,err=pcall(f.fetch);native,web,cookie_calls=f.counts()
expect(not ok and err=='shelf_source/native_unavailable' and native==1 and web==0 and cookie_calls==0,"native-only leaked into Web fallback")
for _,change in ipairs({{current=false},{cookies={}},{cookies={wr_vid='123',wr_skey='different-web-access'}},{mode='native'}}) do
    f=fixture('gateway');f.change{api_key='',cookies=jar}
    f.change{cookie_callback=function() f.change(change) end}
    ok,err=pcall(f.fetch)
    expect(not ok and err=='shelf_source/session_changed',"stale Web response was allowed to update shelf")
end
f=fixture('gateway');f.change{api_key='',cookies=jar,cookie_fail=true}
ok,err=pcall(f.fetch)
expect(not ok and err=='shelf_source/web_unavailable',"Web failure exposed its response or cookie")
f=fixture('gateway');f.change{api_key='',cookies={wr_vid='456',wr_skey='synthetic-web-access'}}
expect(not Source.ready(f.settings,f.store),"mismatching Web owner is considered logged in")
f=fixture('gateway');f.change{api_key='',cookies={wr_vid='123',wr_gid='guest-only-id'}}
expect(not Source.ready(f.settings,f.store),"guest identity was accepted as authenticated Web access")
local binary=Source.normalize({books={{bookId='1',title='Binary',secret=false,finishReading=false,isTop=false,finished=1}}}).books[1]
expect(binary.secret==0 and binary.finishReading==0 and binary.isTop==false and binary.finished==1,'explicit false flags dropped or independent finished metadata merged')
binary=Source.normalize({books={{bookId='1',title='Invalid',secret=2,finishReading='1',isTop='true',finished=1}}}).books[1]
expect(binary.secret==nil and binary.finishReading==nil and binary.isTop==nil and binary.finished==1,'invalid API flags became explicit states')
print("PASS: " .. checks .. " shelf source routing/normalization/account checks")
