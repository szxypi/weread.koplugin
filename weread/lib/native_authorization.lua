-- E-Ink QR protocol validated by scripts/verify_eink_login.py on 2026-11-08.
-- Adapted from MiuRead shelf_client.lua (AGPL-3.0-only). No persistence,
-- Web-Cookie conversion or diagnostic payloads. Renewal follows
-- scripts/verify_eink_renewal.py's real two-renewal/readback check on 2026-11-08.
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
    raw = type(raw) == "string" and raw or table.concat(chunks)
    if #raw > MAX_BYTES or size > MAX_BYTES then fail(stage, "response_limit") end
    if code < 200 or code >= 300 then fail(stage, "http_" .. tostring(code)) end
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

function Auth:read_shelf(credentials)
    self:_current("shelf")
    if type(credentials) ~= "table" or not vid(credentials.vid) or not text(credentials.accessToken, 8192) then
        fail("shelf", "invalid_credentials")
    end
    if self.expected_vid and vid(credentials.vid) ~= self.expected_vid then fail("shelf", "account_mismatch") end
    local shelf = self:_request("shelf", BASE .. "/shelf/sync", nil, credentials)
    if type(shelf.books) ~= "table" then fail("shelf", "invalid") end
    for key in pairs(shelf.books) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #shelf.books then fail("shelf", "invalid") end
    end
    return shelf
end

-- Single-book membership writes verified by the owner's bounded Python
-- add/readback/remove/readback experiment on 2026-11-10. Never renew or retry.
function Auth:write_shelf_membership(credentials, book_id, operation, on_dispatch)
    if type(book_id)~='string' or #book_id>20 or not book_id:match('^[1-9]%d*$')
        or operation~='add' and operation~='remove' then fail('shelf_write','invalid') end
    if type(credentials)~='table' or vid(credentials.vid)~=self.expected_vid
        or not text(credentials.accessToken,8192) then fail('shelf_write','invalid_credentials') end
    local path=operation=='add' and '/shelf/add' or '/shelf/delete'
    return self:_request('shelf_write',BASE..path,{bookIds={book_id}},credentials,nil,on_dispatch)
end

-- Read-only bookstore queries verified by verify_native_discovery.py.
function Auth:read_discovery(credentials, kind, options)
    options = options or {}
    if type(credentials) ~= "table" or not vid(credentials.vid) or not text(credentials.accessToken, 8192) then
        fail("discovery", "invalid_credentials")
    end
    if self.expected_vid and vid(credentials.vid) ~= self.expected_vid then fail("discovery", "account_mismatch") end
    local cursor = tonumber(options.cursor) or 0
    if cursor < 0 or cursor > 2147483647 or cursor % 1 ~= 0 then fail("discovery", "invalid_cursor") end
    local path, params
    if kind == "search" then
        if not text(options.keyword, 512) then fail("discovery", "invalid_keyword") end
        path, params = "/store/search", { keyword = options.keyword, scope = 10 }
    elseif kind == "similar" then
        local id = tostring(options.book_id or "")
        if #id > 20 or not id:match("^[1-9]%d*$") then fail("discovery", "invalid_book") end
        path, params = "/book/detailinfo", { bookId = id, listtypes = 2, synckey = 0 }
        if options.session_id ~= nil and options.session_id ~= "" then
            if not text(options.session_id, 512) then fail("discovery", "invalid_session") end
            params.sessionId = options.session_id
        end
    elseif kind == "recommend" then path, params = "/book/recommend", {}
    else fail("discovery", "invalid_kind") end
    params.maxIdx, params.count = cursor, 20
    local keys, query = {}, {}
    for key in pairs(params) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do query[#query + 1] = key .. "=" .. Protocol.urlencode(params[key]) end
    return self:_request("discovery_" .. kind, BASE .. path .. "?" .. table.concat(query, "&"), nil, credentials)
end

-- Native metadata verified by verify_native_metadata.py before Lua integration.
function Auth:read_book_metadata(credentials, book_id)
    if type(credentials) ~= "table" or not vid(credentials.vid) or not text(credentials.accessToken, 8192) then
        fail("metadata", "invalid_credentials")
    end
    if self.expected_vid and vid(credentials.vid) ~= self.expected_vid then fail("metadata", "account_mismatch") end
    if type(book_id) ~= "string" and type(book_id) ~= "number" then fail("metadata", "invalid_book") end
    book_id = tostring(book_id)
    -- CB_ metadata GETs verified independently before expanding this reader.
    if not require("weread.lib.read_access").display_book_id(book_id) then fail("metadata", "invalid_book") end
    return self:_request("metadata", BASE .. "/book/info?bookId=" .. Protocol.urlencode(book_id), nil, credentials)
end

-- Read-only chapter annotations verified against real nonempty replies first.
function Auth:read_annotations(credentials, kind, book_id, chapter_uid, batch)
    local Data = require("weread.lib.native_annotation_data")
    if type(credentials) ~= "table" or not vid(credentials.vid) or not text(credentials.accessToken, 8192) then
        fail("annotations", "invalid_credentials")
    end
    if self.expected_vid and vid(credentials.vid) ~= self.expected_vid then fail("annotations", "account_mismatch") end
    book_id, chapter_uid = Data.book_id(book_id), Data.chapter_uid(chapter_uid)
    if not book_id then fail("annotations", "invalid_book") end
    if kind == "underlines" then
        return self:_request("annotations_underlines", BASE .. "/book/underlines?bookId=" .. Protocol.urlencode(book_id)
            .. "&chapterUid=" .. Protocol.urlencode(chapter_uid) .. "&synckey=0", nil, credentials)
    elseif kind == "thoughts" then
        Data.batch(batch, self.client)
        return self:_request("annotations_thoughts", BASE .. "/book/readreviews", {
            bookId = book_id, chapterUid = tonumber(chapter_uid), cht2sMode = "", reviews = batch,
        }, credentials)
    end
    fail("annotations", "invalid_kind")
end

-- Own marks GET verified by verify_my_cloud_marks.py before Lua integration.
function Auth:read_my_cloud_marks(credentials, book_id)
    if not require('weread.lib.my_cloud_marks').id(book_id) then fail('my_marks','invalid_book') end
    if type(credentials)~='table' or not vid(credentials.vid) or not text(credentials.accessToken,8192) then
        fail('my_marks','invalid_credentials')
    end
    if self.expected_vid and vid(credentials.vid)~=self.expected_vid then fail('my_marks','account_mismatch') end
    return self:_request('my_marks',BASE..'/book/bookmarklist?bookId='..book_id..'&synckey=0',nil,credentials)
end

-- Personal listType=11 and progressive count prefixes verified in Python.
function Auth:read_my_cloud_thoughts(credentials,book_id,count)
    local Data=require('weread.lib.my_cloud_thoughts')
    if not Data.id(book_id) or type(count)~='number' or count<1 or count>Data.MAX_ROWS or count%1~=0 then fail('my_thoughts','invalid_query') end
    if type(credentials)~='table' or not vid(credentials.vid) or not text(credentials.accessToken,8192) then fail('my_thoughts','invalid_credentials') end
    if self.expected_vid and vid(credentials.vid)~=self.expected_vid then fail('my_thoughts','account_mismatch') end
    return self:_request('my_thoughts',BASE..'/review/list?bookId='..book_id..'&listType=11&listMode=0&mine=1&synckey=0&count='..count,nil,credentials)
end

-- Payloads and readback semantics verified by the user-authorized Python
-- create/edit/delete roundtrip. No renewal or write replay exists here.
function Auth:write_my_thought(credentials,operation,body,on_dispatch)
    if type(credentials)~='table' or vid(credentials.vid)~=self.expected_vid or not text(credentials.accessToken,8192)
        or type(on_dispatch)~='function' then fail('my_thought_write','invalid_credentials') end
    if not require('weread.lib.thought_edit_contract').validate_body(operation,body) then fail('my_thought_write','invalid_payload') end
    local path=operation=='create' and '/review/add' or operation=='edit' and '/review/useredit' or '/review/delete'
    return self:_request('my_thought_write',BASE..path,body,credentials,nil,on_dispatch)
end

-- Exact ordinary-highlight creation/removal and independent readback verified
-- by verify_highlight_trial.py. No automatic renewal or write replay.
function Auth:write_my_highlight(credentials,operation,body,on_dispatch)
    if type(credentials)~='table' or vid(credentials.vid)~=self.expected_vid or not text(credentials.accessToken,8192)
        or type(on_dispatch)~='function' then fail('my_highlight_write','invalid_credentials') end
    if not require('weread.lib.mark_edit_contract').validate_body(operation,body) then fail('my_highlight_write','invalid_payload') end
    local path=operation=='create' and '/book/addBookmark' or '/book/removeBookmark'
    return self:_request('my_highlight_write',BASE..path,body,credentials,nil,on_dispatch)
end

-- Four statistics modes and historical month verified by the Python prototype.
function Auth:read_statistics(credentials, mode, base_time)
    local Data = require("weread.lib.statistics_data")
    if type(credentials) ~= "table" or not vid(credentials.vid) or not text(credentials.accessToken, 8192) then
        fail("statistics", "invalid_credentials")
    end
    if self.expected_vid and vid(credentials.vid) ~= self.expected_vid then fail("statistics", "account_mismatch") end
    base_time = base_time or 0
    if not Data.mode(mode) or not Data.base(base_time) then fail("statistics", "invalid_period") end
    return self:_request("statistics", BASE .. "/readdata/detail?baseTime=" .. Protocol.urlencode(base_time)
        .. "&mode=" .. Protocol.urlencode(mode), nil, credentials)
end

function Auth:verify()
    self:_current("verify")
    local credentials = self.pending_credentials
    if not credentials then fail("verify", "unavailable") end
    local shelf = self:read_shelf(credentials)
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

function Auth:renew(previous)
    self:_current("renewal")
    if self.pending_credentials then return self:verify() end
    if self.renewal_attempted or self.uid then fail("renewal", "unavailable") end
    if type(previous) ~= "table" or not vid(previous.vid) or not text(previous.accessToken, 8192)
        or not text(previous.refreshToken, 8192) or not text(previous.deviceId, 32) or #previous.deviceId ~= 32 then
        fail("renewal", "invalid_credentials")
    end
    local account = vid(previous.vid)
    if self.expected_vid and account ~= self.expected_vid then fail("renewal", "account_mismatch") end
    local random, timestamp = tonumber(self.digits(3)) % 999 + 1, self.now_ms()
    if type(timestamp) ~= "number" or timestamp ~= timestamp or timestamp % 1 ~= 0
        or timestamp < 1 or timestamp > 4102444800000 then fail("renewal", "invalid_clock") end
    local body = { deviceId = previous.deviceId, deviceName = "BOOX", deviceType = 3,
        timestamp = timestamp, random = random, trackId = "", refreshToken = previous.refreshToken,
        inBackground = 0, kickType = 1, refCgi = "",
        signature = Crypto.sha256_hex(string.format("%.0f", timestamp) .. previous.deviceId .. tostring(random)) }
    local data = self:_request("renewal", BASE .. "/login", body, nil, nil, function() self.renewal_attempted = true end)
    if vid(data.vid) ~= account then fail("renewal", "account_mismatch") end
    -- Real responses omit refreshToken. The original token was successfully
    -- reused for a second renewal and shelf read in the Python owner probe.
    local refresh = data.refreshToken
    if refresh == nil then refresh = previous.refreshToken end
    if not text(data.accessToken, 8192) or not text(refresh, 8192) then fail("renewal", "invalid") end
    self.pending_credentials = { vid = account, deviceId = previous.deviceId,
        accessToken = data.accessToken, refreshToken = refresh }
    return self:verify()
end

return Auth
