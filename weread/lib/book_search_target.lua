-- Adapt an untrusted search hit to the existing source-verification path.
-- A successful projection is local navigation only, never an upload grant.
local Target=require('weread.lib.my_mark_target')
local M={}

function M.row(book,hit)
    if type(book)~='string' or not book:match('^[1-9]%d*$') or #book>20
        or type(hit)~='table' or hit.source_verified~=false
        or type(hit.chapter_uid)~='string' or not hit.chapter_uid:match('^[1-9]%d*$') then return nil end
    local uid=tonumber(hit.chapter_uid)
    if not uid or uid>2147483647 or uid%1~=0 or type(hit.start)~='number' or type(hit.finish)~='number'
        or hit.start%1~=0 or hit.finish%1~=0 or hit.start<0 or hit.finish<=hit.start or hit.finish>2147483647 then return nil end
    local row={type=1,bookId=book,chapterUid=uid,markText=hit.text,
        range=string.format('%.0f-%.0f',hit.start,hit.finish)}
    if not Target.can_locate(row) then return nil end
    return row
end

function M.project(raw,book,hit)
    local row=M.row(book,hit)
    if not row then return nil,'book_search_target/invalid' end
    return Target.project(raw,book,hit.chapter_uid,row)
end

return M
