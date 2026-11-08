-- One bounded native grant; never loaded through LuaSettings' backup fallback.
-- Separate from Web settings so a delayed native save cannot overwrite cookies.
local LuaSettings = require("luasettings")
local Store = {}
Store.__index = Store

local function valid_text(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("[%z%c]")
end

local function valid_credentials(value)
    return type(value) == "table" and valid_text(value.vid, 32) and value.vid:match("^[1-9]%d*$")
        and valid_text(value.accessToken, 8192) and valid_text(value.refreshToken, 8192)
        and valid_text(value.deviceId, 32) and #value.deviceId == 32
end

local function same(a, b)
    if a == nil or b == nil then return a == b end
    for _, key in ipairs({ "vid", "accessToken", "refreshToken", "deviceId", "epoch", "verified_at", "book_count" }) do
        if a[key] ~= b[key] then return false end
    end
    return true
end

function Store:new(settings)
    return setmetatable({ settings = settings, path = settings.data_dir .. "/native-authorization.lua" }, self)
end

function Store:_read()
    local file = io.open(self.path, "rb")
    if not file then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(self.path) then return nil, "unavailable" end
        return { revision = 0 }
    end
    local bytes = file:read(65537)
    file:close()
    if not bytes or #bytes > 65536 then return nil, "unavailable" end
    local chunk = loadstring(bytes)
    if not chunk then return nil, "unavailable" end
    setfenv(chunk, {})
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.revision) ~= "number"
        or data.revision < 0 or data.revision % 1 ~= 0 or data.revision > 9007199254740990 then return nil, "unavailable" end
    if data.authorization ~= nil and (not valid_credentials(data.authorization)
        or type(data.authorization.epoch) ~= "number") then return nil, "unavailable" end
    return data
end

function Store:read()
    local data, err = self:_read()
    if not data then return nil, nil, err end
    local value = data.authorization
    if value and self.settings:auth_scope_matches({ vid = value.vid, epoch = value.epoch }) then
        return value, data.revision
    end
    return nil, data.revision
end

function Store:_write(value, scope, revision)
    if not self.settings:auth_scope_matches(scope) then return false, "account_changed" end
    local previous = self:_read()
    if not previous then return false, "unavailable" end
    if previous.revision ~= revision then return false, "replaced" end
    local record = { revision = revision + 1, authorization = value }
    local ok = pcall(function()
        local output = LuaSettings:open(self.path)
        output.data = record
        output:flush()
    end)
    local actual = self:_read()
    -- Flush does not report all write failures; only claim success after a
    -- fresh primary-file read and a second account/session check.
    if not ok or not actual or actual.revision ~= record.revision or not same(actual.authorization, value)
        or not self.settings:auth_scope_matches(scope) then return false, "save_failed" end
    os.remove(self.path .. ".old")
    return true, record.revision
end

function Store:save(credentials, scope, revision, count)
    if not valid_credentials(credentials) or type(scope) ~= "table" or credentials.vid ~= scope.vid
        or type(count) ~= "number" or count < 0 or count % 1 ~= 0 then return false, "invalid" end
    local value = { vid = credentials.vid, accessToken = credentials.accessToken, refreshToken = credentials.refreshToken,
        deviceId = credentials.deviceId, epoch = scope.epoch, verified_at = os.time(), book_count = count }
    return self:_write(value, scope, revision)
end

function Store:clear(scope, revision)
    return self:_write(nil, scope, revision)
end

return Store
