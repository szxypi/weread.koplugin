-- Normalize case and Unicode presentation for local shelf search.
local loaded, utf8proc = pcall(require, "ffi/utf8proc")
local Search = {}

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

function Search.prepare(keyword)
    if type(keyword) ~= "string" or keyword == "" then return nil end
    local needle = fold(keyword)
    -- A nonempty query made only of ignorable characters must not match all.
    return needle ~= "" and needle or string.lower(keyword)
end

function Search.matches(book, needle)
    if not needle then return true end
    if type(book) ~= "table" then return false end
    for _, field in ipairs({ "title", "author", "bookId", "book_id" }) do
        local value = book[field]
        if type(value) == "number" and (field == "bookId" or field == "book_id") then value = tostring(value) end
        if type(value) == "string" and fold(value):find(needle, 1, true) then return true end
    end
    return false
end

return Search
