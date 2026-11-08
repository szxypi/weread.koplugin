-- Captured E-Ink access for read-only requests, without altering credentials.
local Crypto = require("weread.lib.crypto")
local M = {}

function M.capture(settings, store)
    local scope = settings.get_auth_scope and settings:get_auth_scope()
    if not scope or not settings:auth_scope_matches(scope) or (not store and not settings.data_dir) then return end
    store = store or require("weread.lib.native_credentials"):new(settings)
    local credentials, revision, err, pending = store:read()
    if err or not credentials or credentials.vid ~= scope.vid then return end
    return { credentials = credentials, store = store, scope = scope, revision = revision, renewal_pending = pending == true,
        fingerprint = Crypto.sha256_hex(table.concat({ scope.vid, tostring(scope.epoch), tostring(revision), credentials.accessToken }, "\0")) }
end

function M.matches(settings, selected)
    if not selected then return false end
    local current = M.capture(settings, selected.store)
    return current ~= nil and current.fingerprint == selected.fingerprint
end

return M
