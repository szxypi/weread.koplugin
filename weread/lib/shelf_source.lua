-- Read-only shelf routing. The native GET contract was verified by the Python
-- owner-scan prototype. Native `version` is not assumed to be Web bookVersion.
local Auth = require("weread.lib.native_authorization")
local Cookie = require("weread.lib.cookie")
local Crypto = require("weread.lib.crypto")
local M = {}
local WEB_COOKIES = { "wr_vid", "wr_skey", "wr_rt", "wr_fp", "wr_ql", "wr_pf" }

local function fail(kind) error("shelf_source/" .. kind, 0) end
local function array(value)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end
    end
    return true
end
local function text(value, maximum)
    return type(value) == "string" and #value <= maximum and not value:find("[%z%c]")
end
local function id(value)
    if type(value) == "number" then
        if value < 1 or value % 1 ~= 0 or value > 9007199254740990 then return nil end
        value = string.format("%.0f", value)
    end
    return text(value, 256) and value ~= "" and value or nil
end
local function number(value)
    local n = tonumber(value)
    return n and n == n and n >= 0 and n < math.huge and n or nil
end

function M.mode(settings)
    local shelf = settings:get("shelf", {})
    local mode = type(shelf) == "table" and shelf.source
    return (mode == "native" or mode == "gateway") and mode or "auto"
end

local function web_snapshot(settings, scope)
    if not scope or not settings:auth_scope_matches(scope) then return nil end
    local cookies = settings:get("cookies", {})
    if type(cookies) ~= "table" or tostring(cookies.wr_vid or "") ~= scope.vid
        or type(cookies.wr_skey) ~= "string" or #cookies.wr_skey < 8 then return nil end
    local snapshot = {}
    for _, key in ipairs(WEB_COOKIES) do
        local value = cookies[key]
        if value ~= nil then
            if type(value) ~= "string" or #value > 4096 or value:find('[%z%c%s;"\\]')
                or value:find('[\128-\255]') then return nil end
            snapshot[key] = value
        end
    end
    return snapshot, Crypto.sha256_hex(Cookie.to_header(snapshot))
end

function M.web_revision(settings)
    local scope = settings.get_auth_scope and settings:get_auth_scope()
    local _, revision = web_snapshot(settings, scope)
    return revision
end

function M.selection(settings, store)
    local mode = M.mode(settings)
    local scope = settings.get_auth_scope and settings:get_auth_scope() or nil
    local result = { mode = mode, scope = scope }
    if settings.get_auth_scope and not scope then
        local account = settings:get("account", {})
        result.invalid_scope = settings:get_auth_scope(true) ~= nil
            or (type(account) == "table" and tostring(account.user_vid or "") ~= "")
    end
    if mode ~= "gateway" and scope and settings.data_dir and settings:auth_scope_matches(scope) then
        store = store or require("weread.lib.native_credentials"):new(settings)
        result.credentials, result.revision, result.storage_error, result.renewal_pending = store:read()
        result.store = store
    end
    result.has_gateway = type(settings:get("api_key", "")) == "string" and settings:get("api_key", "") ~= ""
    result.web_cookies, result.web_revision = web_snapshot(settings, scope)
    return result
end

function M.ready(settings, store)
    local selected = M.selection(settings, store)
    if selected.invalid_scope then return false, "login_required" end
    if selected.mode == "native" then
        return selected.credentials ~= nil, selected.credentials and nil or "native_required"
    end
    return selected.credentials ~= nil or selected.has_gateway or selected.web_cookies ~= nil, "login_required"
end

function M.normalize(data, kind)
    if type(data) ~= "table" or not array(data.books) or (data.archive ~= nil and not array(data.archive)) then fail("invalid_snapshot") end
    if #data.books > 5000 or #(data.archive or {}) > 1000 then fail("invalid_snapshot") end
    local books, archives, seen = {}, {}, {}
    for _i, source in ipairs(data.books) do
        local book_id = type(source) == "table" and id(source.bookId)
        if not book_id or seen[book_id] or not text(source.title, 4096) then fail("invalid_snapshot") end
        seen[book_id] = true
        local book = { bookId = book_id, title = source.title, author = text(source.author, 4096) and source.author or "",
            readUpdateTime = number(source.readUpdateTime) or 0 }
        book[kind == "web" and "_web_shelf_version" or "_native_version"] = number(source.version)
        for _j, key in ipairs({ "cover", "coverUrl", "format" }) do
            if text(source[key], 8192) then book[key] = source[key] end
        end
        for _j, key in ipairs({ "finishReading", "finished", "secret" }) do
            if source[key] == 0 or source[key] == 1 then book[key] = source[key] end
        end
        books[#books + 1] = book
    end
    for _i, source in ipairs(data.archive or {}) do
        if type(source) ~= "table" or not array(source.bookIds) or #source.bookIds > 5000 then fail("invalid_snapshot") end
        local archive = { archiveId = id(source.archiveId), name = text(source.name, 4096) and source.name or "", bookIds = {} }
        for _j, value in ipairs(source.bookIds) do
            local book_id = id(value)
            if not book_id then fail("invalid_snapshot") end
            archive.bookIds[#archive.bookIds + 1] = book_id
        end
        archives[#archives + 1] = archive
    end
    return { books = books, archive = archives }
end

function M.fetch(client, options)
    options = options or {}
    local settings = client.settings
    local selected = M.selection(settings, options.store)
    local function current(check_grant, check_web)
        if selected.invalid_scope then return false end
        if options.is_current and options.is_current() ~= true then return false end
        if M.mode(settings) ~= selected.mode then return false end
        if selected.scope and not settings:auth_scope_matches(selected.scope) then return false end
        if check_grant and selected.credentials then
            local credentials, revision = selected.store:read()
            if not credentials or revision ~= selected.revision then return false end
        end
        if check_web and M.web_revision(settings) ~= selected.web_revision then return false end
        return true
    end
    if not current(true) then fail("session_changed") end
    local fallback
    if options.skip_native and selected.mode == "auto" then
        selected.credentials, selected.revision, fallback = nil, nil, true
    end
    if selected.credentials then
        local auth = Auth:new(client, { expected_vid = selected.scope.vid, is_current = function() return current(true) end })
        local ok, result = pcall(function() return M.normalize(auth:read_shelf(selected.credentials)) end)
        auth:cancel()
        if not current(true) then fail("session_changed") end
        if ok then
            result._shelf_source, result._native_revision = "native", selected.revision
            return result, 200, {}
        end
        if result == "native_auth/shelf/http_401" and options.recover_auth and not selected.renewal_pending then
            fail("native_expired")
        end
        if selected.mode == "native" then fail("native_unavailable") end
        fallback = true
    elseif selected.mode == "native" then
        fail("native_required")
    end
    if not current(true) then fail("session_changed") end
    local gateway_error, attempted_gateway
    if selected.has_gateway or not selected.web_cookies then
        attempted_gateway = true
        local ok, result, code, headers = pcall(client.get_gateway_shelf, client)
        if not current(true) then fail("session_changed") end
        if ok and type(result) == "table" and array(result.books) and (result.archive == nil or array(result.archive)) then
            result._shelf_source, result._native_fallback = "gateway", fallback
            result._native_revision = selected.credentials and selected.revision or nil
            return result, code, headers
        end
        gateway_error = ok and "shelf_source/invalid_snapshot" or result
    end
    if selected.web_cookies then
        if not current(true, true) then fail("session_changed") end
        local ok, result = pcall(function() return M.normalize(client:get_web_shelf(selected.web_cookies), "web") end)
        if not current(true, true) then fail("session_changed") end
        if not ok then fail("web_unavailable") end
        result._shelf_source, result._web_revision = "web", selected.web_revision
        result._native_fallback, result._gateway_fallback = fallback, attempted_gateway
        result._native_revision = selected.credentials and selected.revision or nil
        return result, 200, {}
    end
    error(gateway_error or "shelf_source/unavailable", 0)
end

return M
