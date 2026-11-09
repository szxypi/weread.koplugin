-- Strict reader response projection. Python prototype verified on real owner
-- responses before this port. Does not assign source units or upload authority.
local M={}
local reasons={progress_invalid=true,progress_book_mismatch=true,progress_rejected=true,
    progress_not_found=true,progress_ambiguous=true}
local function fail(reason) error(reason or 'progress_invalid',0) end
local function identity(value)
    if type(value)=='number' then
        if value~=value or value<0 or value>9007199254740991 or value%1~=0 then return end
        value=string.format('%.0f',value)
    end
    if type(value)=='string' and #value<=128 and value:match('^[A-Za-z0-9][A-Za-z0-9_-]*$') then return value end
end
local function numeric(value,maximum,integer)
    if type(value)~='number' and type(value)~='string' or type(value)=='string' and #value>64 then fail() end
    if type(value)=='string' and not value:match('^%s*[+-]?[%d.]+[eE]?[+-]?%d*%s*$') then fail() end
    local n=tonumber(value)
    if not n or n~=n or n<0 or n>maximum or integer and n%1~=0 then fail() end
    return n
end
local function numbers(node,names,maximum,integer)
    local first
    for _i,key in ipairs(names) do
        if node[key]~=nil then
            local n=numeric(node[key],maximum,integer)
            if first~=nil and first~=n then fail() end
            first=n
        end
    end
    return first
end
local function find_node(data,book_id)
    local candidates,visited={},0
    local mismatch,rejected=false,false
    local function visit(node,depth)
        if type(node)~='table' then return end
        visited=visited+1
        if depth>7 or visited>512 then fail() end
        for _i,key in ipairs({'bookId','book_id'}) do
            if node[key]~=nil and identity(node[key])~=book_id then mismatch=true;return end
        end
        for _i,key in ipairs({'errcode','errCode'}) do
            if node[key]~=nil and node[key]~=0 and node[key]~='0' then rejected=true;return end
        end
        if node.succ~=nil and node.succ~=true and node.succ~=1 and node.succ~='1' then rejected=true;return end
        for _i,key in ipairs({'progress','readingProgress','bookProgress'}) do
            if node[key]~=nil and type(node[key])~='table' then candidates[#candidates+1]=node;return end
        end
        for _key,child in pairs(node) do visit(child,depth+1) end
    end
    visit(data,0)
    if #candidates>1 then fail('progress_ambiguous') end
    if #candidates==0 then fail(mismatch and 'progress_book_mismatch' or rejected and 'progress_rejected' or 'progress_not_found') end
    return candidates[1]
end
local function project(data,book_id,source)
    book_id=identity(book_id)
    if not book_id then fail('progress_book_mismatch') end
    local node=find_node(data,book_id)
    local percent=numbers(node,{'progress','readingProgress','bookProgress'},100)
    if percent==nil then fail() end
    local offset=numbers(node,{'chapterOffset','chapterPos','offset','chapter_offset'},2147483647,true)
    local index=numbers(node,{'chapterIdx','chapterIndex','chapter_idx'},1000000,true)
    local updated=numbers(node,{'updateTime','updatedAt','update_time'},9007199254740991,true)
    local summary=node.summary
    if summary==nil then summary=node.chapterTitle end
    if summary==nil then summary='' end
    if type(summary)~='string' or #summary>16384 or summary:find('%z') then fail() end
    local uid,uid_identity
    for _i,key in ipairs({'chapterUid','chapterId','chapter_uid'}) do
        if node[key]~=nil then
            local id=identity(node[key])
            if not id or uid_identity and uid_identity~=id then fail() end
            if uid==nil then uid=node[key] end
            uid_identity=id
        end
    end
    return {book_id=book_id,percent=percent,raw_percent=percent,chapter_uid=uid,chapter_idx=index or 0,
        chapter_offset=offset or 0,has_chapter_offset=offset~=nil,updated_at=updated or 0,
        summary=summary,source=source or 'unknown',position_basis='raw_percent'}
end
function M.project(data,book_id,source)
    local ok,result=pcall(project,data,book_id,source)
    if ok then return result end
    return nil,reasons[result] and result or 'progress_invalid'
end
return M
