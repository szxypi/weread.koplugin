package.path = "./?.lua;./?/init.lua;" .. package.path
local Auth = require("weread.lib.native_authorization")
local Crypto = require("weread.lib.crypto")
local checks = 0
local function eq(got, expected, label)
    checks = checks + 1
    assert(got == expected, label .. ": " .. tostring(got) .. " ~= " .. tostring(expected))
end
local function expect(value, label) checks = checks + 1 assert(value, label) end
local function fixture(options)
    local requests, queue, bodies = {}, {}, {}
    local next_response
    local client = {
        json_encode = function(self, body)
            if self.fail_encode then error("private-encode-data") end
            bodies[#bodies + 1] = body return "encoded"
        end,
        json_decode = function()
            if next_response.invalid_json then error("private-json-body") end
            return next_response.data
        end,
        request = function(_self, request)
            requests[#requests + 1] = request
            next_response = assert(table.remove(queue, 1), "fixture missing response")
            if next_response.callback then next_response.callback() end
            if next_response.raise then error("private-transport-url-token") end
            local status = next_response.code
            if status == nil then status = 200 elseif status == false then status = nil end
            return next_response.raw or "fixture", status, {}
        end,
    }
    options = options or {}
    options.digits = function(n) return string.rep("1", n) end
    options.now_ms = options.now_ms or function() return 1794100000123 end
    local auth = Auth:new(client, options)
    local function push(data, code) queue[#queue + 1] = { data = data, code = code } end
    local function begin()
        push({ signature = "private-ticket", timeStamp = 1794100000 })
        push({ errcode = 0, uuid = "private-uuid" })
        local url = auth:begin()
        expect(url:find("private-uuid", 1, true), "QR target uses server UUID")
    end
    local function confirm()
        push({ wx_errcode = 405, wx_code = "private-code" })
        eq(auth:poll(), "confirmed", "owner approval observed")
    end
    return { auth = auth, client = client, requests = requests, queue = queue, bodies = bodies, push = push, begin = begin, confirm = confirm }
end
local f = fixture({ expected_vid = "123" })
f.begin()
f.push({ wx_errcode = 408 })
eq(f.auth:poll(), "pending", "unscanned QR waits")
f.push({ wx_errcode = 404 })
eq(f.auth:poll(), "scanned", "scan waits for confirmation")
expect(f.requests[#f.requests].url:find("last=408", 1, true), "long-poll state reused")
f.confirm()
f.push({ vid = 123, accessToken = "private-access", refreshToken = "private-refresh" })
f.push({ books = { { bookId = "fixture-book" } } })
local credentials, shelf = f.auth:finish()
eq(credentials.vid, "123", "numeric VID normalized")
eq(credentials.accessToken, "private-access", "private access credential returned only to caller")
eq(credentials.refreshToken, "private-refresh", "private renewal credential retained for future adapter")
eq(#shelf.books, 1, "authorized shelf verified")
local body = f.bodies[1]
eq(body.timestamp, 1794100000123, "millisecond timestamp preserved")
eq(body.random, 112, "nonce within protocol range")
expect(body.deviceId:match("^eink334691225%d+$") and #body.deviceId == 32, "device identifier matches verified protocol")
expect(body.installId:match("^eink31%d+$") and #body.installId == 32, "installation identifier matches protocol")
eq(body.signature, Crypto.sha256_hex("1794100000123" .. body.deviceId .. "112"), "canonical signature input")
eq(body.code, "private-code", "confirmed code sent once")
eq(body.isFromQrcode, 1, "QR login type")
for i, request in ipairs(f.requests) do
    expect(request.skip_cookie and request.persist_response_cookies == false and request.sensitive, "isolated sensitive transport")
    eq(request.headers.Cookie, nil, "Web cookies never copied")
    eq(request.headers.Authorization, nil, "gateway key never copied")
    if i < #f.requests then eq(request.headers.accessToken, nil, "credentials not sent to QR services") end
end
eq(f.requests[#f.requests].headers.accessToken, "private-access", "shelf request uses native token")
eq(f.auth.pending_credentials, nil, "internal credentials cleared after verification")
eq(f.auth.confirmed_code, nil, "code not retained")
local before = #f.requests
eq(pcall(f.auth.finish, f.auth), false, "completed login cannot replay")
eq(#f.requests, before, "completed login sends no further request")

for _, code in ipairs({ 402, 403, 499 }) do
    f = fixture(); f.begin(); f.push({ wx_errcode = code })
    eq(f.auth:poll(), code == 402 and "expired" or "declined", "terminal QR state")
    eq(pcall(f.auth.poll, f.auth), false, "terminal session stays closed")
end
f = fixture(); f.begin(); f.auth:cancel()
before = #f.requests
eq(pcall(f.auth.poll, f.auth), false, "cancelled session stops")
eq(#f.requests, before, "cancel sends no HTTP")

local current = true
f = fixture({ is_current = function() return current end }); f.begin(); f.confirm()
f.queue[#f.queue + 1] = { data = { vid = "123", accessToken = "private-access", refreshToken = "private-refresh" },
    callback = function() current = false end }
eq(pcall(f.auth.finish, f.auth), false, "account/session change during login ignored")
eq(#f.requests, 4, "changed account never reads shelf")
eq(f.auth.pending_credentials, nil, "changed session keeps no token")

f = fixture({ expected_vid = "456" }); f.begin(); f.confirm()
f.push({ vid = "123", accessToken = "private-access", refreshToken = "private-refresh" })
local ok, err = pcall(f.auth.finish, f.auth)
expect(not ok and err:find("account_mismatch", 1, true), "different scan account rejected")
eq(#f.requests, 4, "wrong account has no shelf request")
eq(f.auth.pending_credentials, nil, "wrong account tokens not retained")

f = fixture(); f.begin(); f.confirm()
f.queue[#f.queue + 1] = { raise = true }
ok, err = pcall(f.auth.finish, f.auth)
expect(not ok and not err:find("private-", 1, true), "transport details never escape")
before = #f.requests
eq(pcall(f.auth.finish, f.auth), false, "lost login receipt never reuses code")
eq(#f.requests, before, "uncertain login is not replayed")

f = fixture(); f.begin(); f.confirm()
f.push({ vid = "123", accessToken = "private-access", refreshToken = "private-refresh" })
f.push({}, 503)
eq(pcall(f.auth.finish, f.auth), false, "shelf verification failure blocks completion")
eq(#f.bodies, 1, "only one login POST")
f.push({ books = {} })
credentials = f.auth:finish()
eq(credentials.vid, "123", "read-only shelf retry can complete")
eq(#f.bodies, 1, "shelf retry does not repeat login")

for _, response in ipairs({ { code = 302, data = {} }, { code = 429, data = {} }, { code = false },
    { invalid_json = true }, { data = { errcode = 123, errmsg = "private-message" } },
    { raw = string.rep("x", 4*1024*1024+1) } }) do
    f = fixture(); f.queue[#f.queue + 1] = response
    ok, err = pcall(f.auth.begin, f.auth)
    expect(not ok and not err:find("private-", 1, true), "protocol failures are bounded and redacted")
end
for _, response in ipairs({ { vid = "bad", accessToken = "private-access", refreshToken = "private-refresh" },
    { vid = "123", accessToken = "private-access" }, { vid = "123", accessToken = "injected\r\nheader", refreshToken = "r" } }) do
    f = fixture(); f.begin(); f.confirm(); f.push(response)
    eq(pcall(f.auth.finish, f.auth), false, "invalid credentials cannot verify shelf")
    eq(#f.requests, 4, "invalid credentials not sent as headers")
end
f = fixture({ now_ms = function() return math.huge end }); f.begin(); f.confirm()
eq(pcall(f.auth.finish, f.auth), false, "invalid clock blocks login")
eq(#f.bodies, 0, "invalid clock sends no body")
eq(f.auth.login_attempted, nil, "invalid clock does not consume a code before dispatch")
f = fixture(); f.begin(); f.confirm(); f.client.fail_encode = true
ok, err = pcall(f.auth.finish, f.auth)
expect(not ok and not err:find("private-", 1, true), "serialization error is redacted")
eq(f.auth.login_attempted, nil, "failed serialization does not burn approved code")
f.client.fail_encode = false
f.push({ vid = "123", accessToken = "private-access", refreshToken = "private-refresh" })
f.push({ books = {} })
eq(f.auth:finish().vid, "123", "pre-dispatch failure can retry without rescanning")
local previous = { vid = "123", accessToken = "private-old-access", refreshToken = "private-old-refresh",
    deviceId = "eink334691225" .. string.rep("1", 19) }
f = fixture({ expected_vid = "123" })
f.push({ vid = 123, accessToken = "private-new-access" }); f.push({ books = {} })
local renewed = f.auth:renew(previous)
eq(renewed.refreshToken, previous.refreshToken, "real omitted refresh token is retained")
eq(renewed.deviceId, previous.deviceId, "renewal reuses device")
eq(previous.accessToken, "private-old-access", "renewal does not mutate prior grant")
body = f.bodies[1]
eq(body.refreshToken, previous.refreshToken, "renewal body carries current refresh token")
eq(body.code, nil, "renewal carries no QR code")
eq(body.installId, nil, "renewal does not invent an install identifier")
eq(body.signature, Crypto.sha256_hex("1794100000123" .. previous.deviceId .. "112"), "renewal canonical signature")
eq(body.inBackground, 0, "renewal foreground field")
eq(body.kickType, 1, "verified renewal type")
eq(f.requests[1].headers.accessToken, nil, "renewal POST does not send old access header")
eq(f.requests[2].headers.accessToken, "private-new-access", "renewal verifies new access before returning")
eq(pcall(f.auth.renew, f.auth, previous), false, "completed renewal cannot replay")
f = fixture(); f.push({ vid = "123", accessToken = "private-new-access", refreshToken = "private-rotated" }); f.push({ books = {} })
eq(f.auth:renew(previous).refreshToken, "private-rotated", "returned rotation replaces old refresh token")
f = fixture(); f.queue[1] = { raise = true }
ok, err = pcall(f.auth.renew, f.auth, previous)
expect(not ok and not err:find("private-", 1, true), "renewal transport error redacted")
eq(f.auth.renewal_attempted, true, "unknown receipt consumes renewal attempt")
before = #f.requests
eq(pcall(f.auth.renew, f.auth, previous), false, "unknown renewal receipt cannot replay")
eq(#f.requests, before, "unknown renewal sends no second POST")
f = fixture(); f.push({ vid = "123", accessToken = "private-new-access" }); f.push({}, 503)
eq(pcall(f.auth.renew, f.auth, previous), false, "failed renewal shelf read is not verified")
f.push({ books = {} })
eq(f.auth:renew(previous).vid, "123", "pending renewal retries only shelf verification")
eq(#f.bodies, 1, "shelf retry does not post renewal again")
f = fixture({ expected_vid = "456" })
eq(pcall(f.auth.renew, f.auth, previous), false, "wrong owner blocks renewal before HTTP")
eq(#f.requests, 0, "wrong owner dispatches nothing")
print("native_authorization_spec: " .. checks .. " checks")
