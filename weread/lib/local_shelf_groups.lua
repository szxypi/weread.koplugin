-- Device-only shelf groups. Cloud archives remain a separate data source.
local Identity=require('weread.lib.shelf_snapshot')
local M={}
local function array(value,limit)
    if type(value)~='table' or #value>limit then return false end
    local n=0
    for key in pairs(value) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end
        n=n+1
    end
    return n==#value
end
local function name(value)
    if type(value)~='string' or #value>128 or value:find('[%z%c]') then return nil end
    value=require('weread.lib.search_query').trim(value)
    return value~='' and value or nil
end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
function M.empty() return {version=1,next_id=1,groups={}} end
function M.valid(value)
    if type(value)~='table' or value.version~=1 or type(value.next_id)~='number'
        or value.next_id%1~=0 or value.next_id<1 or value.next_id>1000000000 or not array(value.groups,100) then return false end
    for key in pairs(value) do if key~='version' and key~='next_id' and key~='groups' then return false end end
    local ids,names,total={},{},0
    for _,group in ipairs(value.groups) do
        if type(group)~='table' or type(group.id)~='number' or group.id%1~=0 or group.id<1 or group.id>=value.next_id
            or ids[group.id] or not name(group.name) or name(group.name)~=group.name or names[group.name]
            or not array(group.books,5000) then return false end
        for key in pairs(group) do if key~='id' and key~='name' and key~='books' then return false end end
        ids[group.id],names[group.name]=true,true
        local seen={}
        for _,book in ipairs(group.books) do
            if type(book)~='string' or Identity.persisted_identity(book)~=book or seen[book] then return false end
            seen[book]=true;total=total+1
            if total>10000 then return false end
        end
    end
    return true
end
function M.change(value,action)
    if not M.valid(value) or type(action)~='table' then return nil end
    local result=copy(value);local group,index
    for i,item in ipairs(result.groups) do if item.id==action.id then group,index=item,i;break end end
    if action.kind=='create' then
        local label=name(action.name)
        if not label or #result.groups>=100 or result.next_id>=1000000000 then return nil end
        result.groups[#result.groups+1]={id=result.next_id,name=label,books={}};result.next_id=result.next_id+1
    elseif action.kind=='rename' and group then
        group.name=name(action.name);if not group.name then return nil end
    elseif action.kind=='delete' and group then
        table.remove(result.groups,index)
    elseif action.kind=='books' and group and array(action.books,5000) then
        group.books=copy(action.books)
    else return nil end
    return M.valid(result) and result or nil
end
function M.project(value,books,label)
    if not M.valid(value) then return nil end
    local by_id={}
    for _,book in ipairs(type(books)=='table' and books or {}) do
        local id=Identity.persisted_id(book);if id then by_id[id]=book end
    end
    local result={}
    for _,group in ipairs(value.groups) do
        local members={};local missing=false
        for _,id in ipairs(group.books) do
            if by_id[id] then members[#members+1]=by_id[id] else missing=true end
        end
        result[#result+1]={key='local:'..group.id,label=label(group.name),books=members,incomplete=missing or nil,local_group=true}
    end
    return result
end
return M
