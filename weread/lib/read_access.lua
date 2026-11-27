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

-- Older caches may use numeric table keys. Never round a decimal identifier
-- through a floating-point number: adjacent IDs above 2^53 can alias.
function M.cached_key(entries, value)
    if type(entries) ~= 'table' then return nil end
    -- Preserve exact legacy string keys even when they are not numeric.
    if type(value)=='string' and entries[value] ~= nil then return entries[value] end
    local id = M.book_id(value)
    if not id then return nil end
    if entries[id] ~= nil then return entries[id] end
    if #id < 16 or #id == 16 and id <= '9007199254740991' then
        return entries[tonumber(id)]
    end
end
M.cached_chapter=M.cached_key

-- A cache can contain both a string and a legacy numeric key for one UID.
-- Return both candidates so callers that verify file contents can recover
-- from a stale preferred path without guessing a large numeric identifier.
function M.cached_chapter_candidates(entries,value)
    local preferred=M.cached_chapter(entries,value)
    local id=M.book_id(value)
    if type(entries)~='table' or not id then return preferred end
    if #id<16 or #id==16 and id<='9007199254740991' then
        local legacy=entries[tonumber(id)]
        if legacy~=preferred then return preferred,legacy end
    end
    return preferred
end

-- A table key alone is not proof of ownership if stored metadata names a
-- different book. Return a separate conflict so a writer can preserve the entry.
local function exact_book_id(value)
    if type(value)=='string' then return value~='' and value or nil end
    if type(value)=='number' and value>=1 and value<=9007199254740991 and value%1==0 then
        return string.format('%.0f',value)
    end
end

local function verified_cached_book(book,id)
    if book==nil then return nil end
    if type(book)~='table' then return nil,'identity_conflict' end
    for _,field in ipairs({'book_id','bookId'}) do
        if book[field]~=nil and exact_book_id(book[field])~=id then return nil,'identity_conflict' end
    end
    return book
end

function M.cached_book(entries, value)
    local id=exact_book_id(value)
    if not id or type(entries)~='table' then return nil,'invalid_identity' end
    return verified_cached_book(M.cached_key(entries,id),id)
end

function M.load_cached_book(settings,value)
    local id=exact_book_id(value)
    if not id then return nil,'invalid_identity' end
    if type(settings.get_book)=='function' then
        return verified_cached_book(settings:get_book(id,true),id)
    end
    return M.cached_book(settings:get('books',{}),id)
end

-- Writers must not choose between two independently stored legacy indices.
-- Return the numeric key for an unambiguous migration; do not mutate entries.
function M.cached_book_for_update(entries,value)
    local book,reason=M.cached_book(entries,value)
    if reason then return nil,reason end
    local id=exact_book_id(value)
    local numeric=M.book_id(id) and tonumber(id)
    if numeric and numeric<=9007199254740991 and entries[numeric]~=nil then
        if entries[id]~=nil or entries[numeric]~=book then return nil,'identity_conflict' end
        return book,nil,numeric
    end
    return book
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
