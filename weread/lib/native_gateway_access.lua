-- Immutable owner-bound access shared by read-only native/Skill features.
local Crypto = require("weread.lib.crypto")
local Native = require("weread.lib.native_read_access")
local M = {}

function M.capture(settings, store)
    if not settings then return nil, "login_required" end
    local scope = settings.get_auth_scope and settings:get_auth_scope()
    if settings.get_auth_scope and (not scope or not settings:auth_scope_matches(scope)) then return nil, "login_required" end
    local key = settings:get("api_key", "")
    if type(key) ~= "string" or key == "" or #key > 4096 or key:find("[%z%c%s]") then key = nil end
    local native = Native.capture(settings, store)
    if not native and not key then return nil, "native_required" end
    local base = Crypto.sha256_hex((key or "") .. "\0" .. (scope and scope.vid or "") .. "\0" .. tostring(scope and scope.epoch or ""))
    return { native = native, api_key = key, base_revision = base,
        revision = Crypto.sha256_hex((native and native.fingerprint or "") .. "\0" .. (key or "")
            .. "\0" .. (scope and scope.vid or "") .. "\0" .. tostring(scope and scope.epoch or "")) }
end

function M.matches(settings, selected)
    if not selected then return false end
    local current = M.capture(settings, selected.native and selected.native.store)
    return current ~= nil and current.revision == selected.revision
end

return M
