-- Local membership evidence for an atomically saved complete shelf list.
local M={MAX_BOOKS=5000}
local function integer(value,maximum)
    return type(value)=='number' and value>=0 and value<=maximum and value==math.floor(value)
end
local function identity(value)
    if type(value)=='number' then
        if not integer(value,9007199254740990) or value==0 then return nil end
        value=string.format('%.0f',value)
    end
    if type(value)=='string' and #value>=1 and #value<=256 and value~='0' and not value:find('[%z%c]') then return value end
end
function M.id(book)
    if type(book)~='table' then return nil end
    local first,second=identity(book.book_id),identity(book.bookId)
    if book.book_id~=nil and not first or book.bookId~=nil and not second then return nil end
    if first and second and first~=second then return nil end
    return first or second
end
function M.metadata(books,now)
    if type(books)~='table' or #books>M.MAX_BOOKS then return nil end
    local length=0
    for key in pairs(books) do
        if not integer(key,#books) or key==0 then return nil end
        length=length+1
    end
    if length~=#books then return nil end
    local seen={}
    for _i,book in ipairs(books) do
        local id=M.id(book)
        if not id or seen[id] then return nil end
        seen[id]=true
    end
    return {schema=1,book_count=#books,cached_at=integer(now,4102444800) and now or 0}
end
function M.state(metadata,count,on_shelf,updated_at,legacy)
    if legacy then
        if on_shelf==1 then return true,integer(updated_at,4102444800) and updated_at or 0 end
        return nil
    end
    if type(metadata)~='table' or metadata.schema~=1 or not integer(metadata.book_count,M.MAX_BOOKS)
        or not integer(metadata.cached_at,4102444800) or not integer(count,M.MAX_BOOKS)
        or metadata.book_count~=count then return nil end
    for key in pairs(metadata) do
        if key~='schema' and key~='book_count' and key~='cached_at' then return nil end
    end
    if on_shelf==1 then
        if count<1 or updated_at~=metadata.cached_at then return nil end
        return true,metadata.cached_at
    end
    if on_shelf==nil or on_shelf==0 then return false,metadata.cached_at end
end
return M
