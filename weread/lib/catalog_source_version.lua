-- A source version must be explicitly observed in this book's fresh catalogue.
-- Shelf/display metadata is not a fallback, and conflicting aliases stay unknown.
local M={}
local function integer(v) return type(v)=='number' and v%1==0 and v>=1 and v<=2147483647 end
function M.read(payload,id)
    if type(payload)~='table' or type(id)~='string' then return 0 end
    local rows=payload.data or payload.books or payload
    if type(rows)~='table' then return 0 end
    if rows.bookId or rows.book then rows={rows} end
    local found,count,version=nil,0,nil
    for _i,row in ipairs(rows) do
        if type(row)~='table' then return 0 end
        local book=type(row.book)=='table' and row.book or nil
        if tostring(row.bookId or book and book.bookId)==id then found=row;count=count+1 end
    end
    if count~=1 then return 0 end
    local book=type(found.book)=='table' and found.book or nil
    if found.bookId~=nil and tostring(found.bookId)~=id or book and book.bookId~=nil and tostring(book.bookId)~=id then return 0 end
    for _i,node in ipairs(book and {found,book} or {found}) do
        for _j,key in ipairs({'bookVersion','version'}) do
            local value=node[key]
            if value~=nil then
                if not integer(value) or version and version~=value then return 0 end
                version=value
            end
        end
    end
    return version or 0
end
return M
