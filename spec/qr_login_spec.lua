package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end,
        getHeight = function() return 800 end } }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return { warn = function() end, err = function() end }
        end,
    }
end
package.preload["ui/widget/qrmessage"] = function() return {} end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        urlencode = function(value)
            return tostring(value):gsub(" ", "%%20")
        end,
    }
end

local requests = {}
local client = {
    request = function(_self, options)
        requests[#requests + 1] = options
        return "{}", 200, {}
    end,
    decode_http_json = function()
        return { logicCode = "PENDING" }
    end,
}

local QRLogin = require("weread.lib.qr_login")
local login = QRLogin:new({}, client, {})

login:_poll_protocol("uid value", "")
expect(requests[1].url ==
    "https://weread.qq.com/api/auth/getLoginInfo?uid=uid%20value&otp=",
    "empty OTP was not serialized with an explicit value")

login:_poll_protocol("uid value", "1234")
expect(requests[2].url ==
    "https://weread.qq.com/api/auth/getLoginInfo?uid=uid%20value&otp=1234",
    "non-empty OTP was serialized incorrectly")

local function run_login(fingerprint, options)
    options = options or {}
    local protocol_requests, saved = {}, nil
    local responses = {
        { "html", { ["set-cookie"] = "wr_preflight=test-preflight; Path=/" } },
        { { uid = "test-uid" } },
        { { succeed = true, webLoginVid = "900000", accessToken = "test-access", refreshToken = "test-refresh" } },
        { { vid = options.wrong_owner and 900001 or 900000, name = "Test user" } },
        { options.no_key and {} or { apikey = options.bad_key and "test\napi-key" or "test-api-key" },
            options.cookie_change and {["set-cookie"]="wr_vid=900001; Path=/"} or {}, options.key_error and 503 or 200 },
    }
    local protocol_client = {
        request = function(_self, opts)
            protocol_requests[#protocol_requests + 1] = opts
            local response = table.remove(responses, 1)
            return response[1], response[3] or 200, response[2] or {}
        end,
        decode_http_json = function(_self, body) return body end,
    }
    protocol_client.request_follow = protocol_client.request
    local settings = {
        get_device_fingerprint = function() return fingerprint end,
        update_auth = function(_self, credentials, auth_options)
            expect(auth_options.replace_cookies, "login should replace account cookies")
            saved = credentials
        end,
    }
    local protocol_login = QRLogin:new({}, protocol_client, settings)
    local uid = protocol_login:_begin_protocol()
    local result = protocol_login:_poll_protocol(uid)
    local ok = pcall(protocol_login._complete_protocol, protocol_login, result, protocol_login.generation)
    if options.wrong_owner then
        expect(not ok and saved == nil and #protocol_requests == 4, "unverified owner committed credentials or fetched a key")
        return
    end
    if options.cookie_change then
        expect(not ok and saved==nil and #protocol_requests==5,"changed cookie owner was committed")
        return
    end
    expect(ok, "verified Web login failed")
    local expected_urls = {
        "https://weread.qq.com/r/weread-skills",
        "https://weread.qq.com/api/auth/getLoginUid",
        "https://weread.qq.com/api/auth/getLoginInfo?uid=test-uid&otp=",
        "https://weread.qq.com/api/userInfo?userVid=900000",
        "https://weread.qq.com/api/skills/apikeyGet?only_show=1",
    }
    expect(#protocol_requests == #expected_urls, "fingerprint must not introduce a new login chain")
    for i, request in ipairs(protocol_requests) do
        expect(request.url == expected_urls[i], "classic login endpoint changed")
        expect(request.skip_cookie, "login must not inherit old account credentials")
        expect(request.sensitive, "QR authorization diagnostics must be redacted")
        expect(request.headers.Cookie:find("wr_fp=" .. fingerprint, 1, true),
            "fingerprint missing from login request " .. i)
        expect(not request.headers.Cookie:find("wr_gid=", 1, true),
            "fingerprint-only experiment must not add a guest ID")
    end
    expect(protocol_requests[2].headers.Cookie:find("wr_preflight=test-preflight", 1, true),
        "fingerprint must not discard server cookies")
    expect(saved.cookies.wr_fp == fingerprint and saved.cookies.wr_skey == "test-access",
        "completed login must persist both the fingerprint and new credentials")
    expect(saved.api_key == ((options.no_key or options.key_error or options.bad_key) and "" or "test-api-key") and protocol_login.login_cookies == nil,
        "login completion state changed")
    return protocol_requests[2].headers.Cookie
end

expect(run_login("1234567890") ~= run_login("2345678901"),
    "separate device fingerprints must reach the server independently")
run_login("1234567890", { no_key = true })
run_login("1234567890", { key_error = true })
run_login("1234567890", { wrong_owner = true })
run_login("1234567890", { cookie_change = true })
run_login("1234567890", { bad_key = true })

local committed = false
local cancelled = QRLogin:new({}, {}, { update_auth = function() committed = true end })
cancelled._authenticated_get = function(self)
    self:cancel()
    return {vid=900000}, {}
end
expect(not pcall(cancelled._complete_protocol, cancelled,
    {succeed=true,webLoginVid='900000',accessToken='synthetic-access'},cancelled.generation)
    and not committed, "cancelled owner verification saved login")

print("qr_login_spec: " .. checks .. " checks passed")
