-- Typed Web observation for an imported book with no cloud chapter. This is
-- not a position, a dispatch receipt, or permission to initialize progress.
local Access=require('weread.lib.read_access')
local Remote=require('weread.lib.remote_progress')
local M={}

local fields={kind=true,book_id=true,index_present=true,summary_present=true,updated_present=true,
    chapter_uid=true,chapter_offset=true,raw_percent=true}
local function imported(book)
    return type(book)=='string' and book:sub(1,3)=='CB_' and Access.display_book_id(book)==book
end
local function integer(value)
    return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=9007199254740991
end

function M.none(value)
    if type(value)~='table' or value.kind~='cb_no_chapter' or not imported(value.book_id)
        or value.chapter_uid~='0' or value.chapter_offset~=0 or value.raw_percent~=0
        or type(value.index_present)~='boolean' or type(value.summary_present)~='boolean'
        or type(value.updated_present)~='boolean'
        or value.index_present and value.chapter_idx~=0 or not value.index_present and value.chapter_idx~=nil
        or value.summary_present and value.summary~='' or not value.summary_present and value.summary~=nil
        or value.updated_present and not integer(value.updated_at) or not value.updated_present and value.updated_at~=nil then return false end
    for key in pairs(value) do
        if not fields[key] and not (key=='chapter_idx' and value.index_present)
            and not (key=='summary' and value.summary_present)
            and not (key=='updated_at' and value.updated_present) then return false end
    end
    return true
end

function M.from(raw,book)
    if not imported(book) then return nil end
    local position,reason,provided=Remote.project(raw,book,'web')
    local node=Remote.node(raw,book)
    if reason or not position or not node or not provided.chapter_uid or tostring(position.chapter_uid)~='0'
        or not provided.chapter_offset or position.chapter_offset~=0 or position.raw_percent~=0
        or position.summary~='' or provided.chapter_idx and position.chapter_idx~=0
        or node.summary~=nil and node.summary~='' or node.chapterTitle~=nil and node.chapterTitle~='' then return nil end
    local value={kind='cb_no_chapter',book_id=book,chapter_uid='0',chapter_offset=0,raw_percent=0,
        index_present=provided.chapter_idx,summary_present=provided.summary,
        updated_present=node.updateTime~=nil or node.updatedAt~=nil or node.update_time~=nil}
    if value.index_present then value.chapter_idx=0 end
    if value.summary_present then value.summary='' end
    if value.updated_present then value.updated_at=position.updated_at end
    return M.none(value) and value or nil
end

function M.equal(first,second)
    if not M.none(first) or not M.none(second) then return false end
    for key,value in pairs(first) do if second[key]~=value then return false end end
    for key,value in pairs(second) do if first[key]~=value then return false end end
    return true
end

function M.matches(raw,expected)
    return M.none(expected) and M.equal(M.from(raw,expected.book_id),expected) or false
end

return M
