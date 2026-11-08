package.path = "./?.lua;./?/init.lua;" .. package.path
local checks = 0
local function expect(value, label) checks = checks + 1 assert(value, label) end
local path = os.tmpname()
os.remove(path)
local mode, writes = "normal", 0
local function dump(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    local out = { "{" }
    for key, item in pairs(value) do out[#out + 1] = "[" .. dump(key) .. "]=" .. dump(item) .. "," end
    return table.concat(out) .. "}"
end
package.preload["luasettings"] = function()
    return { open = function(_self, file)
        return { flush = function(self)
            writes = writes + 1
            if mode == "raise" then error("private filesystem data") end
            if mode == "silent" then return end
            local handle = assert(io.open(file, "w"))
            handle:write(mode == "corrupt" and "broken" or "return " .. dump(self.data))
            handle:close()
        end }
    end }
end
package.preload["libs/libkoreader-lfs"] = function() return { attributes = function() return nil end } end
local scope = { vid = "123", epoch = 1 }
local current = { vid = "123", epoch = 1 }
local settings = { data_dir = "/unused", auth_scope_matches = function(_self, value)
    return value and current.vid == value.vid and current.epoch == value.epoch
end }
local Store = require("weread.lib.native_credentials")
local store = Store:new(settings)
store.path = path
local credentials = { vid = "123", accessToken = "test-native-access", refreshToken = "test-native-refresh",
    deviceId = string.rep("1", 32) }
local value, revision = store:read()
expect(value == nil and revision == 0, "fresh authorization is empty")
local ok, next_revision = store:save(credentials, scope, revision, 26)
expect(ok and next_revision == 1, "verified authorization saved")
local reopened = Store:new(settings)
reopened.path = path
value, revision = reopened:read()
expect(value and value.accessToken == credentials.accessToken and revision == 1 and value.book_count == 26,
    "fresh object reads primary file")
local before = writes
ok, value = store:save(credentials, scope, 0, 26)
expect(not ok and value == "replaced" and writes == before, "stale concurrent save cannot replace authorization")
current.epoch = 2
expect(store:read() == nil, "same VID with fresh login rejects old native grant")
ok, value = store:save(credentials, scope, 1, 26)
expect(not ok and value == "account_changed" and writes == before, "old login cannot persist")
current.epoch, current.vid = 1, "456"
expect(store:read() == nil, "another account cannot read credentials")
current.vid = "123"
for _, failure in ipairs({ "raise", "silent", "corrupt" }) do
    mode = failure
    ok, value = store:save(credentials, scope, 1, 26)
    expect(not ok and value == "save_failed", "failed flush never claims saved: " .. failure)
end
mode = "normal"
-- Corruption is rejected rather than falling back to an old credential file.
local backup = assert(io.open(path .. ".old", "w"))
backup:write("return " .. dump({ revision = 1, authorization = credentials })) backup:close()
value, revision = store:read()
expect(value == nil and revision == nil, "corrupted primary never loads backup tokens")
os.remove(path)
ok, revision = store:save(credentials, scope, 0, 26)
expect(ok and revision == 1, "synthetic grant restored for clear check")
expect(store:clear(scope, revision), "clear saved")
value, revision = store:read()
expect(value == nil and revision == 2, "clear survives reopen with revision")
expect(io.open(path .. ".old", "r") == nil, "old credential backup removed")
local invalid = { vid = "123", accessToken = "secret\n", refreshToken = "test", deviceId = string.rep("1", 32) }
before = writes
expect(not store:save(invalid, scope, 2, 26) and writes == before, "malformed credentials never written")
os.remove(path)
os.remove(path .. ".old")
print("PASS: " .. checks .. " native credential persistence/readback/session checks")
