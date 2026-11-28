-- A transient upload candidate, never a grant to send or persist source text.
local Dom = require('weread.lib.source_dom')
local Access = require('weread.lib.read_access')
local Catalog = require('weread.lib.chapter_catalog')
local M = {}
local function identifier(value)
    if type(value)=='number' and value%1==0 then value=tostring(value) end
    return type(value)=='string' and #value<=20 and value:match('^[1-9]%d*$') and value or nil
end
-- Build the same unambiguous UID/index mapping as chapter_index in one pass.
-- A malformed identifier anywhere invalidates the catalog; a malformed or
-- duplicated index invalidates that UID only, as in chapter_index.
function M.chapter_indices(chapters)
    if type(chapters)~='table' or #chapters<1 or #chapters>Catalog.MAX_CHAPTERS then return nil end
    local indexes,counts={},{}
    for _i,row in ipairs(chapters) do
        if type(row)~='table' then return nil end
        local id
        for _j,key in ipairs(Catalog.UID_FIELDS) do
            if row[key]~=nil then
                local value=identifier(row[key])
                if not value or id and id~=value then return nil end
                id=value
            end
        end
        if not id then return nil end
        counts[id]=(counts[id] or 0)+1
        local index,valid=nil,true
        for _j,key in ipairs(Catalog.INDEX_FIELDS) do
            local value=row[key]
            if value~=nil then
                if type(value)~='number' or value%1~=0 or value<0 or value>1000000
                    or index and index~=value then valid=false;break end
                index=value
            end
        end
        if counts[id]==1 and valid then indexes[id]=index else indexes[id]=nil end
    end
    return indexes
end
function M.chapter_index(chapters,uid)
    if type(chapters)~='table' or #chapters<1 or #chapters>Catalog.MAX_CHAPTERS then return nil end
    local selected,count=nil,0
    for _i,row in ipairs(chapters) do
        if type(row)~='table' then return nil end
        local id
        for _j,key in ipairs(Catalog.UID_FIELDS) do
            if row[key]~=nil then
                local value=identifier(row[key])
                if not value or id and id~=value then return nil end
                id=value
            end
        end
        if not id then return nil end
        if id==uid then
            local index
            for _j,key in ipairs(Catalog.INDEX_FIELDS) do
                local value=row[key]
                if value~=nil then
                    if type(value)~='number' or value%1~=0 or value<0 or value>1000000
                        or index and index~=value then return nil end
                    index=value
                end
            end
            if index==nil then return nil end
            selected,count=index,count+1
        end
    end
    return count==1 and selected or nil
end
local function project(position,summary,chapters,percent,cb)
    local book=type(position)=='table' and (cb and Access.display_book_id(position.book_id) or identifier(position.book_id))
    if type(position)~='table' or position.basis~='filtered_xhtml_utf16' or position.upload_verified~=false
        or not book or cb and book:sub(1,3)~='CB_' or not identifier(position.chapter_uid)
        or type(position.chapter_offset)~='number' or position.chapter_offset%1~=0
        or position.chapter_offset<0 or position.chapter_offset>2147483647
        or type(percent)~='number' or percent%1~=0 or percent<0 or percent>100
        or type(summary)~='string' or #summary==0 or #summary>80 or summary:find('[%z%c]')
        or Dom.normalize(summary)~=summary then return nil,'candidate_invalid' end
    local count=0
    for _char in summary:gmatch('[%z\1-\127\194-\244][\128-\191]*') do count=count+1 end
    if count>20 then return nil,'candidate_invalid' end
    local uid=identifier(position.chapter_uid)
    local index=M.chapter_index(chapters,uid)
    if index==nil then return nil,'candidate_catalog' end
    return {book_id=book,chapter_uid=uid,chapter_idx=index,
        chapter_offset=position.chapter_offset,percent=percent,summary=summary,
        basis='filtered_xhtml_utf16',upload_verified=false}
end
function M.project(position,summary,chapters,percent) return project(position,summary,chapters,percent,false) end
-- Imported candidates remain transient; a separate guarded proof grants dispatch.
function M.project_cb(position,summary,chapters,percent) return project(position,summary,chapters,percent,true) end
function M.same(first,second)
    if type(first)~='table' or type(second)~='table' then return false end
    for key,value in pairs(first) do if second[key]~=value then return false end end
    for key,value in pairs(second) do if first[key]~=value then return false end end
    return true
end
return M
