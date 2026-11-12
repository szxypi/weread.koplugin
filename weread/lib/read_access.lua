-- Captured, session-bound access for read-only display requests.
local Crypto = require("weread.lib.crypto")
local Source = require("weread.lib.shelf_source")
local M = {}

function M.book_id(value)
    if type(value) ~= "string" and type(value) ~= "number" then return end
    local id = tostring(value)
    if #id <= 20 and id:match("^[1-9]%d*$") then return id end
end

-- Display-only CB_ GETs were independently verified by verify_cb_progress.py.
-- Keep the numeric validator for account, chapter and synchronization callers.
function M.display_book_id(value)
    local numeric = M.book_id(value)
    if numeric then return numeric end
    if type(value) == "string" and #value <= 67 and value:match("^CB_[A-Za-z0-9]+$") then return value end
end

function M.capture(settings)
    if not settings then return end
    local scope = settings.get_auth_scope and settings:get_auth_scope()
    if settings.get_auth_scope and (not scope or not settings:auth_scope_matches(scope)) then return end
    local key = settings:get("api_key", "")
    if type(key) ~= "string" or key == "" or #key > 4096 or key:find("[%z%c%s]") then key = nil end
    local web = Source.web_access(settings)
    if not key and not web then return end
    return { gateway = key and { kind = "gateway", api_key = key } or nil,
        web = web and { kind = "web", cookies = web.cookies } or nil,
        revision = Crypto.sha256_hex(table.concat({ scope and scope.vid or "", scope and tostring(scope.epoch) or "",
            key or "", web and web.revision or "" }, "\0")) }
end

function M.matches(settings, selected)
    local current = M.capture(settings)
    return current ~= nil and selected ~= nil and current.revision == selected.revision
end

return M
