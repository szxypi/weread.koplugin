-- Source coordinates need a unique explicit catalog index. List order and
-- default zeros never grant position or synchronization authority.
local Remote=require('weread.lib.remote_progress')
local M={}
local function positive(value)
    if type(value)=='number' and value==value and value%1==0 and value>=1 and value<=9007199254740991 then value=string.format('%.0f',value) end
    return type(value)=='string' and #value<=20 and value:match('^[1-9]%d*$') and value or nil
end
local function catalog_index(chapters,uid)
    if type(chapters)~='table' or #chapters<1 or #chapters>10000 then return nil end
    local selected,seen,indices=nil,{},{}
    for _i,row in ipairs(chapters) do
        if type(row)~='table' then return nil end
        local id,index
        for _j,key in ipairs({'chapterUid','chapterId','chapter_uid'}) do
            if row[key]~=nil then
                local v=positive(row[key]);if not v or id and id~=v then return nil end;id=v
            end
        end
        for _j,key in ipairs({'chapterIdx','chapterIndex','chapter_idx'}) do
            if row[key]~=nil then
                local v=row[key]
                if type(v)~='number' or v~=v or v%1~=0 or v<0 or v>1000000 or index and index~=v then return nil end
                index=v
            end
        end
        if not id or seen[id] or index~=nil and indices[index] then return nil end
        seen[id]=true;if index~=nil then indices[index]=true end
        if id==uid then selected=index end
    end
    return selected
end
function M.resolve(raw,book_id,chapters,source)
    local p,reason,provided=Remote.project(raw,book_id,source)
    if not p then return nil,reason end
    if tostring(p.chapter_uid)=='0' and p.raw_percent==0 and p.has_chapter_offset and p.chapter_offset==0
        and p.summary=='' and (not provided.chapter_idx or p.chapter_idx==0) then return nil,'progress_no_chapter' end
    local uid=positive(p.chapter_uid)
    if not uid or not p.has_chapter_offset then return nil,'progress_source_incomplete' end
    local index=catalog_index(chapters,uid)
    if index==nil or provided.chapter_idx and p.chapter_idx~=index then return nil,'progress_source_incomplete' end
    p.chapter_idx,p.has_chapter_index,p.chapter_index_source=index,true,provided.chapter_idx and 'response' or 'catalog'
    return p
end
return M
