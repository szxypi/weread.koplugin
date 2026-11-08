-- Statistics reads use the same owner-bound native/Skill access as discovery.
local Access = require("weread.lib.native_gateway_access")
local Auth = require("weread.lib.native_authorization")
local Data = require("weread.lib.statistics_data")
local M = { capture = Access.capture, matches = Access.matches }
local function fail(reason) error("statistics/" .. reason, 0) end

function M.fetch(client, mode, base_time, selected, options)
    options = options or {}
    base_time = base_time or 0
    if not Data.mode(mode) or not Data.base(base_time) then fail("invalid_period") end
    selected = selected or M.capture(client.settings)
    if not selected then fail("access_required") end
    local function current() if not M.matches(client.settings, selected) then fail("session_changed") end end
    current()
    local kind = options.source_kind or (not options.skip_native and selected.native and "native" or "gateway")
    if kind == "native" then
        if not selected.native then fail("source_changed") end
        local auth = Auth:new(client, { expected_vid = selected.native.scope.vid,
            is_current = function() return M.matches(client.settings, selected) end })
        local ok, raw = pcall(auth.read_statistics, auth, selected.native.credentials, mode, base_time)
        auth:cancel(); current()
        if ok then
            local out = Data.project(raw, mode, base_time)
            out._stats_source = "native"
            return out
        end
        if raw == "native_auth/statistics/http_401" and options.recover_auth and not selected.native.renewal_pending then fail("native_expired") end
        local reason = tostring(raw)
        local fallback = reason:match("/http_40[13]$") or reason:match("/http_50%d$")
            or reason:match("/transport$") or reason:match("/timeout$")
        if not fallback or options.source_kind or not selected.api_key then fail("native_unavailable") end
    elseif kind ~= "gateway" then fail("source_changed") end
    if not selected.api_key then fail("access_required") end
    local ok, raw = pcall(client.get_gateway_read_stats, client, mode, base_time, selected.api_key)
    current()
    if not ok then fail("gateway_unavailable") end
    local out = Data.project(raw, mode, base_time)
    out._stats_source = "gateway"
    return out
end

return M
