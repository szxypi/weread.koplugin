-- E-Ink QR protocol validated by scripts/verify_eink_login.py on 2026-11-08.
-- Adapted from MiuRead shelf_client.lua (AGPL-3.0-only). No persistence, writes
-- to the shelf, Web-Cookie conversion, automatic renewal or diagnostic payloads.
local Crypto = require("weread.lib.crypto")
local Protocol = require("weread.lib.protocol")
local Auth = {}
Auth.__index = Auth
local BASE = "https://i.weread.qq.com"
local MAX_BYTES = 4 * 1024 * 1024
local HEADERS = {
    baseapi = "30", appver = "2.1.2.10245900", basever = "2.1.2.10245900", osver = "11", channelId = "900",
    ["Accept"] = "application/json",
    ["User-Agent"] = "WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)",
}

local function fail(stage, kind)
    error("native_auth/" .. stage .. "/" .. kind, 0)
end

local function text(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("[%z%c]")
end

local function vid(value)
    if type(value) ~= "string" and type(value) ~= "number" then return nil end
    local result = tostring(value)
    return #result <= 32 and result:match("^[1-9]%d*$") and result or nil
end

local function copy(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function secure_digits(count)
    local source = io.open("/dev/urandom", "rb")
    if not source then fail("random", "unavailable") end
    local bytes = source:read(count)
    source:close()
    if not bytes or #bytes ~= count then fail("random", "unavailable") end
    return (bytes:gsub(".", function(char) return tostring(char:byte() % 10) end))
end

function Auth:new(client, options)
    options = options or {}
    if options.expected_vid ~= nil and not vid(options.expected_vid) then fail("account", "invalid") end
    return setmetatable({ client = assert(client), digits = options.digits or secure_digits,
        now_ms = options.now_ms or function() return os.time() * 1000 end,
        expected_vid = options.expected_vid and vid(options.expected_vid), is_current = options.is_current }, self)
end

function Auth:cancel()
    self.closed, self.uid, self.last, self.confirmed_code, self.pending_credentials = true, nil, nil, nil, nil
end

function Auth:_current(stage)
    if self.closed then fail(stage, "closed") end
    if self.is_current then
        local ok, current = pcall(self.is_current)
        if not ok or current ~= true then self:cancel() fail(stage, "session_changed") end
    end
end

function Auth:_request(stage, url, body, credentials, timeout, on_dispatch)
    self:_current(stage)
    local headers = copy(HEADERS)
    if credentials then headers.vid, headers.accessToken = credentials.vid, credentials.accessToken end
    local payload
    if body then
        local ok, encoded = pcall(self.client.json_encode, self.client, body)
        if not ok or type(encoded) ~= "string" then fail(stage, "invalid_payload") end
        payload, headers["Content-Type"] = encoded, "application/json"
    end
    local chunks, size = {}, 0
    self:_current(stage)
    if on_dispatch then on_dispatch() end
    local ok, raw, code = pcall(self.client.request, self.client, {
        url = url, method = body and "POST" or "GET", body = payload, headers = headers,
        skip_cookie = true, persist_response_cookies = false, sensitive = true, diagnostic_api = "native_" .. stage,
        timeout = timeout or { 5, 15 }, sink = function(chunk)
            if chunk then
                size = size + #chunk
                if size > MAX_BYTES then return nil, "response_limit" end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
    })
    self:_current(stage)
    if not ok then fail(stage, "transport") end
    code = tonumber(code)
    if not code then fail(stage, "timeout") end
    if code < 200 or code >= 300 then fail(stage, "http_" .. tostring(code)) end
    raw = type(raw) == "string" and raw or table.concat(chunks)
    if #raw > MAX_BYTES or size > MAX_BYTES then fail(stage, "response_limit") end
    local parsed, data = pcall(self.client.json_decode, self.client, raw)
    if not parsed or type(data) ~= "table" then fail(stage, "invalid_json") end
    local error_code = data.errcode or data.errCode
    if error_code ~= nil and error_code ~= 0 then fail(stage, "rejected") end
    return data
end

function Auth:begin()
    self:_current("begin")
    if self.uid then fail("begin", "already_started") end
    local ticket = self:_request("ticket", BASE .. "/wxticket?nonceStr=weread")
    if not text(ticket.signature, 1024) or not tonumber(ticket.timeStamp) then fail("ticket", "invalid") end
    local qr = self:_request("qr", "https://open.weixin.qq.com/connect/sdk/qrconnect?appid=wxab9b71ad2b90ff34"
        .. "&noncestr=weread&timestamp=" .. Protocol.urlencode(ticket.timeStamp)
        .. "&scope=" .. Protocol.urlencode("snsapi_userinfo,snsapi_timeline,snsapi_friend")
        .. "&signature=" .. Protocol.urlencode(ticket.signature))
    if qr.errcode ~= 0 or not text(qr.uuid, 1024) then fail("qr", "invalid") end
    self.uid = qr.uuid
    return "https://open.weixin.qq.com/connect/confirm?uuid=" .. Protocol.urlencode(self.uid)
end

function Auth:poll()
    self:_current("poll")
    if not self.uid or self.login_attempted then fail("poll", "unavailable") end
    if self.confirmed_code then return "confirmed" end
    local result = self:_request("poll", "https://long.open.weixin.qq.com/connect/l/qrconnect?f=json&uuid="
        .. Protocol.urlencode(self.uid) .. (self.last and "&last=" .. tostring(self.last) or ""), nil, nil, { 3, 9 })
    if result.wx_errcode == 405 then
        if not text(result.wx_code, 4096) then fail("poll", "invalid") end
        self.confirmed_code = result.wx_code
        return "confirmed"
    elseif result.wx_errcode == 404 or result.wx_errcode == 408 then
        self.last = result.wx_errcode
        return result.wx_errcode == 404 and "scanned" or "pending"
    end
    self:cancel()
    return result.wx_errcode == 402 and "expired" or "declined"
end

function Auth:verify()
    self:_current("verify")
    local credentials = self.pending_credentials
    if not credentials then fail("verify", "unavailable") end
    local shelf = self:_request("shelf", BASE .. "/shelf/sync", nil, credentials)
    if type(shelf.books) ~= "table" then fail("shelf", "invalid") end
    for key in pairs(shelf.books) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #shelf.books then fail("shelf", "invalid") end
    end
    local verified = copy(credentials)
    self:cancel()
    return verified, shelf
end

function Auth:finish()
    self:_current("login")
    -- Once /login may have reached the server, only shelf verification can be
    -- retried. Never replay a consumed code after a timeout or lost receipt.
    if self.pending_credentials then return self:verify() end
    if self.login_attempted or not self.confirmed_code then fail("login", "unavailable") end
    local device = "eink334691225" .. self.digits(19)
    local install = "eink31" .. self.digits(26)
    local random = tonumber(self.digits(3)) % 999 + 1
    local timestamp = self.now_ms()
    if type(timestamp) ~= "number" or timestamp ~= timestamp or timestamp % 1 ~= 0
        or timestamp < 1 or timestamp > 4102444800000 then fail("login", "invalid_clock") end
    local body = { deviceId = device, deviceName = "BOOX", deviceType = 3, timestamp = timestamp, random = random,
        trackId = "", signature = Crypto.sha256_hex(string.format("%.0f", timestamp) .. device .. tostring(random)),
        code = self.confirmed_code, appFirstInstall = 1, installId = install, isAutoLogout = 0, isFromQrcode = 1 }
    local data = self:_request("login", BASE .. "/login", body, nil, nil, function()
        self.login_attempted, self.confirmed_code = true, nil
    end)
    local account = vid(data.vid)
    if not account or not text(data.accessToken, 8192) or not text(data.refreshToken, 8192) then fail("login", "invalid") end
    if self.expected_vid and account ~= self.expected_vid then self:cancel() fail("login", "account_mismatch") end
    self.pending_credentials = { vid = account, accessToken = data.accessToken, refreshToken = data.refreshToken, deviceId = device }
    return self:verify()
end

return Auth
