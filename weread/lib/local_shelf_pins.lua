-- Device-only pins never alter or stand in for WeRead's cloud pin flag.
local Identity=require('weread.lib.shelf_snapshot')
local M={KEY='shelf_local_pins_v1'}

function M.empty() return {version=1,books={}} end
function M.valid(state)
    if type(state)~='table' or state.version~=1 or type(state.books)~='table' or #state.books>5000 then return false end
    for key in pairs(state) do if key~='version' and key~='books' then return false end end
    local seen,count={},0
    for index,id in pairs(state.books) do
        if type(index)~='number' or index%1~=0 or index<1 or index>#state.books
            or type(id)~='string' or Identity.persisted_identity(id)~=id or seen[id] then return false end
        seen[id]=true;count=count+1
    end
    return count==#state.books
end
function M.contains(state,book)
    if not M.valid(state) then return false end
    local id=Identity.persisted_id(book)
    if not id then return false end
    for _,entry in ipairs(state.books) do if entry==id then return true end end
    return false
end
function M.index(state)
    if not M.valid(state) then return nil end
    local result={};for _,id in ipairs(state.books) do result[id]=true end
    return result
end
function M.same(a,b)
    if a==nil or b==nil then return a==b end
    if not M.valid(a) or not M.valid(b) or #a.books~=#b.books then return false end
    for i,id in ipairs(a.books) do if b.books[i]~=id then return false end end
    return true
end
function M.toggle(state,book)
    if not M.valid(state) then return nil end
    local id=Identity.persisted_id(book)
    if not id then return nil end
    local result=M.empty();local found=false
    for _,entry in ipairs(state.books) do
        if entry==id then found=true else result.books[#result.books+1]=entry end
    end
    if not found then result.books[#result.books+1]=id end
    return M.valid(result) and result or nil
end
return M
