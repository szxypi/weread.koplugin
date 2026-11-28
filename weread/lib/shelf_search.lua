-- Normalize case and Unicode presentation for local shelf search.
local loaded, utf8proc = pcall(require, "ffi/utf8proc")
local Search = {}
local fields = { "title", "author", "authors", "bookId", "book_id" }
local MAX_FOLDS = 4096
local MAX_FOLD_BYTES = 256 * 1024

local function fold(value)
    if loaded and type(utf8proc) == "table" and type(utf8proc.count) == "function"
            and type(utf8proc.lowercase) == "function" and not value:find("\0", 1, true) then
        local ok, result = pcall(function()
            local _, valid = utf8proc.count(value)
            if valid ~= true then return nil end
            return utf8proc.lowercase(value, true)
        end)
        if ok and type(result) == "string" then return result end
    end
    return string.lower(value)
end

-- Share completed folds within one shelf snapshot. Once full, new strings
-- still match normally without increasing the memory used by the cache.
function Search.cached_fold()
    local values = {}
    local count, bytes = 0, 0
    return function(value)
        local normalized = values[value]
        if normalized ~= nil then return normalized end
        normalized = fold(value)
        local cost = #value + #normalized
        if count < MAX_FOLDS and cost <= MAX_FOLD_BYTES - bytes then
            values[value] = normalized
            count, bytes = count + 1, bytes + cost
        end
        return normalized
    end
end

function Search.prepare(keyword)
    if type(keyword) ~= "string" or keyword == "" then return nil end
    local needle = fold(keyword)
    -- A nonempty query made only of ignorable characters must not match all.
    return needle ~= "" and needle or string.lower(keyword)
end

function Search.find(value, needle, normalize)
    if type(value) ~= "string" or type(needle) ~= "string" then return nil end
    local folded = (normalize or fold)(value)
    return folded:find(needle, 1, true), folded
end

function Search.contains(value, needle)
    return Search.find(value, needle) ~= nil
end

function Search.terms(needle)
    return require("weread.lib.search_query").words(needle)
end

function Search.matches(book, needle, terms, normalize)
    if not needle then return true end
    if type(book) ~= "table" then return false end
    normalize = normalize or fold
    local values = {}
    for _, field in ipairs(fields) do
        local value = book[field]
        if type(value) == "number" and (field == "bookId" or field == "book_id") then value = tostring(value) end
        if type(value) == "string" then
            value = normalize(value)
            if type(needle) == "string" and value:find(needle, 1, true) then return true end
            values[#values + 1] = value
        end
    end
    terms = terms or Search.terms(needle)
    if #terms < 2 then return false end
    for _, term in ipairs(terms) do
        local found = false
        for _, value in ipairs(values) do
            if value:find(term, 1, true) then found = true; break end
        end
        if not found then return false end
    end
    return true
end

return Search
