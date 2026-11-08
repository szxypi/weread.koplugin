-- Display-only book fields. Never project reader positions, credentials or
-- source versions into a metadata refresh. Verified by the Python prototype.
local Access = require("weread.lib.read_access")
local NativeAccess = require("weread.lib.native_read_access")
local Auth = require("weread.lib.native_authorization")
local Crypto = require("weread.lib.crypto")
local M = {}
local TEXT = { author = 4096, translator = 4096, intro = 65536, publisher = 4096, isbn = 256, cover = 8192 }
local NUMBERS = { wordCount = 1e10, newRating = 1000, newRatingCount = 1e10 }

local function fail(reason) error("book_metadata/" .. reason, 0) end
local function text(value, limit, multiline)
    return type(value) == "string" and #value <= limit
        and not value:find(multiline and "[%z\1-\8\11-\31\127]" or "[%z%c]")
end
local function number(value, limit)
    return type(value) == "number" and value == value and value >= 0 and value <= limit
end

function M.normalize(source, book_id)
    book_id = Access.book_id(book_id)
    if not book_id or type(source) ~= "table" or tostring(source.bookId or "") ~= book_id
        or not text(source.title, 4096) or source.title == "" then fail("invalid") end
    if (source.errcode ~= nil and tonumber(source.errcode) ~= 0) or (source.errCode ~= nil and tonumber(source.errCode) ~= 0)
        or (source.succ ~= nil and source.succ ~= true and tonumber(source.succ) ~= 1) then fail("invalid") end
    local result = { bookId = book_id, title = source.title }
    for key, limit in pairs(TEXT) do
        if text(source[key], limit, key == "intro") then result[key] = source[key] end
    end
    for key, limit in pairs(NUMBERS) do
        if number(source[key], limit) then result[key] = source[key] end
    end
    local category = source.categoryName or source.category
    if text(category, 4096) then result.categoryName = category end
    if text(source.publishTime, 128) or number(source.publishTime, 1e12) then result.publishTime = source.publishTime end
    return result
end

function M.from_reader(html, book_id, decode)
    if type(html) ~= "string" or #html > 4 * 1024 * 1024 then fail("invalid") end
    local encoded = html:match([[window%.__INITIAL_STATE__%s*=%s*(%{.-%})%s*;%s*%(function]])
    if not encoded then fail("invalid") end
    local ok, state = pcall(decode, encoded)
    if not ok or type(state) ~= "table" or type(state.reader) ~= "table" then fail("invalid") end
    return M.normalize(state.reader.bookInfo, book_id)
end

function M.normalize_native(source, book_id)
    if type(source) ~= "table" then fail("invalid") end
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    if copy.wordCount == nil then copy.wordCount = source.totalWords end
    return M.normalize(copy, book_id)
end

function M.capture(settings, store)
    if not settings then return end
    local native = NativeAccess.capture(settings, store)
    local display = Access.capture(settings)
    if not native and not display then return end
    return { native = native, display = display,
        revision = Crypto.sha256_hex((native and native.fingerprint or "") .. "\0" .. (display and display.revision or "")) }
end

function M.matches(settings, selected)
    if not selected then return false end
    local current = M.capture(settings, selected.native and selected.native.store)
    return current ~= nil and current.revision == selected.revision
end

function M.fetch(client, book_id, selected)
    book_id = Access.book_id(book_id)
    if not book_id then fail("invalid_book") end
    selected = selected or M.capture(client.settings)
    if not selected then fail("access_required") end
    local function current() if not M.matches(client.settings, selected) then fail("session_changed") end end
    current()
    if selected.native then
        local auth = Auth:new(client, { expected_vid = selected.native.scope.vid,
            is_current = function() return M.matches(client.settings, selected) end })
        local ok, value = pcall(auth.read_book_metadata, auth, selected.native.credentials, book_id)
        auth:cancel(); current()
        if ok then return { metadata = M.normalize_native(value, book_id), source = "native" } end
        local reason = tostring(value)
        local fallback = reason:match("/http_40[13]$") or reason:match("/http_50%d$")
            or reason:match("/transport$") or reason:match("/timeout$")
        if not fallback then fail("unavailable") end
    end
    local display = selected.display or {}
    for _, access in ipairs({ display.gateway or false, display.web or false }) do
        if access then
            local ok, value = pcall(client.get_display_book_metadata, client, book_id, access)
            current()
            if ok then
                local normalized, metadata = pcall(M.normalize, value, book_id)
                if normalized then return { metadata = metadata, source = access.kind } end
            end
        end
    end
    fail("unavailable")
end

return M
