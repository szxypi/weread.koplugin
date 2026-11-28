local ShelfGroups=require('weread.lib.shelf_groups')
local ShelfSnapshot=require('weread.lib.shelf_snapshot')
local ShelfFilters=require('weread.lib.shelf_filters')
local Protocol=require('weread.lib.protocol')
local M={KEY='shelf_browse_v1'}

local function bounded_integer(value,minimum,maximum)
    return type(value)=='number' and value>=minimum and value<=maximum and value%1==0
end

function M.same_groups(a,b)
    if #a~=#b then return false end
    for index,key in ipairs(a) do if b[index]~=key then return false end end
    return true
end

function M.normalize(value)
    if type(value)~='table' or value.version~=1 or (value.mode~='books' and value.mode~='public_account')
        or not bounded_integer(value.page,1,ShelfSnapshot.MAX_BOOKS) then return nil end
    local keys=ShelfGroups.normalize(value.group_keys)
    if not keys or value.group_key~=nil and (#keys>0 or not ShelfGroups.normalize({value.group_key})) then return nil end
    local keyword=value.keyword
    if keyword~=nil and (type(keyword)~='string' or keyword=='' or #keyword>1024 or keyword:find('[%z%c]')
        or Protocol.utf8_substr(keyword,#keyword)~=keyword) then return nil end
    local anchor=ShelfSnapshot.persisted_identity(value.book_id)
    local focus=ShelfSnapshot.persisted_identity(value.focus_book_id)
    local y=type(value.scroll_offset)=='table' and value.scroll_offset.y
    return {version=1,mode=value.mode,page=value.page,keyword=keyword,group_key=value.group_key,group_keys=keys,
        book_id=anchor,focus_book_id=focus,
        filters=value.mode=='books' and type(value.filters)=='table' and ShelfFilters.normalize(value.filters) or nil,
        inset=bounded_integer(value.inset,-1,10000000) and value.inset or nil,
        scroll_offset=bounded_integer(y,0,10000000) and {x=0,y=y} or nil}
end

function M.same(a,b)
    if not a or not b then return false end
    for _,field in ipairs({'mode','page','keyword','group_key','book_id','focus_book_id','inset'}) do
        if a[field]~=b[field] then return false end
    end
    return M.same_groups(a.group_keys,b.group_keys)
        and ShelfFilters.same(a.filters,b.filters)
        and (a.scroll_offset and a.scroll_offset.y)==(b.scroll_offset and b.scroll_offset.y)
end

return M
