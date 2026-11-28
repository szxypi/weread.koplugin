-- Bind an explicit imported-book synchronization choice to a fresh Web point.
local Access=require('weread.lib.read_access')
local Remote=require('weread.lib.remote_progress')
local M={}
local function integer(value,maximum)
    return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=maximum
end
function M.expected(value,book)
    if type(value)~='table' or type(book)~='string' or Access.display_book_id(book)~=book or book:sub(1,3)~='CB_'
        or value.book_id~=book or value.source~='web' or value.has_chapter_index~=true or value.has_chapter_offset~=true then return nil end
    local uid=Access.book_id(value.chapter_uid)
    local percent=value.raw_percent
    if not uid or not integer(value.chapter_idx,1000000) or not integer(value.chapter_offset,2147483647)
        or type(percent)~='number' or percent~=percent or percent<0 or percent>100
        or not integer(value.updated_at,9007199254740991) then return nil end
    return {book_id=book,chapter_uid=uid,chapter_idx=value.chapter_idx,chapter_offset=value.chapter_offset,raw_percent=percent,updated_at=value.updated_at}
end
function M.same(first,second,book)
    local a,b=M.expected(first,book),M.expected(second,book)
    if not a or not b then return false end
    for key,value in pairs(a) do if b[key]~=value then return false end end
    return true
end
function M.matches(raw,expected)
    if type(expected)~='table' then return false end
    local value,reason,provided=Remote.project(raw,expected.book_id,'web')
    return not reason and value~=nil and provided.chapter_uid and provided.chapter_offset
        and Access.book_id(value.chapter_uid)==expected.chapter_uid and value.chapter_offset==expected.chapter_offset
        and value.raw_percent==expected.raw_percent and value.updated_at==expected.updated_at and (not provided.chapter_idx or value.chapter_idx==expected.chapter_idx) or false
end
return M
