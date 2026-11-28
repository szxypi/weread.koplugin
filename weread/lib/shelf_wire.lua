-- Preserve the JSON distinction between an empty array and an empty object
-- whenever the active decoder exposes an array metatable.
local M={}
function M.valid(client,shelf)
    if type(shelf)~='table' then return false end
    local ok,empty=pcall(client.json_decode,client,'[]')
    local array_mt=ok and type(empty)=='table' and getmetatable(empty) or nil
    if not array_mt then return true end
    local function valid(value)
        return type(value)~='table' or next(value)~=nil or getmetatable(value)==array_mt
    end
    if not valid(shelf.books) or not valid(shelf.archive) then return false end
    for _i,archive in ipairs(type(shelf.archive)=='table' and shelf.archive or {}) do
        if type(archive)=='table' and not valid(archive.bookIds) then return false end
    end
    return true
end
return M
