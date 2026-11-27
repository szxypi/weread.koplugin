-- Captured E-Ink access for read-only requests, without altering credentials.
local Crypto = require("weread.lib.crypto")
local M = {}
local guards = setmetatable({}, { __mode = "k" })

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

-- A nested read can reuse a guard for the same settings and captured grant.
-- Each invocation still checks the live session and rereads the grant.
function M.guard(settings, is_current, selected)
    if type(is_current) ~= "function" then return nil end
    local inherited = guards[is_current]
    if inherited and inherited.settings == settings and (not selected or selected == inherited.selected) then
        return is_current, inherited.selected
    end
    selected = selected or M.capture(settings)
    if not selected or selected.renewal_pending then return nil end
    local function current()
        local ok, live = pcall(is_current)
        return ok and live == true and not selected.renewal_pending and M.matches(settings, selected)
    end
    guards[current] = { settings = settings, selected = selected }
    return current, selected
end

return M
