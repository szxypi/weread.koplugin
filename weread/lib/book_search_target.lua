-- Adapt an untrusted search hit to the existing source-verification path.
-- A successful projection is local navigation only, never an upload grant.
local Target=require('weread.lib.my_mark_target')
local Access=require('weread.lib.read_access')
local M={}

function M.row(book,hit)
    if type(book)~='string' or not Access.display_book_id(book)
        or type(hit)~='table' or hit.source_verified~=false
        or type(hit.chapter_uid)~='string' or Access.book_id(hit.chapter_uid)~=hit.chapter_uid then return nil end
    local uid=hit.chapter_uid
    if type(hit.start)~='number' or type(hit.finish)~='number'
        or hit.start%1~=0 or hit.finish%1~=0 or hit.start<0 or hit.finish<=hit.start or hit.finish>2147483647 then return nil end
    local chapter=#uid<=10 and tonumber(uid)<=2147483647 and tonumber(uid) or uid
    local row={type=1,bookId=book,chapterUid=chapter,markText=hit.text,
        range=string.format('%.0f-%.0f',hit.start,hit.finish)}
    if not Target.can_locate_search(row) then return nil end
    return row
end

function M.project(raw,book,hit,format)
    local row=M.row(book,hit)
    if not row then return nil,'book_search_target/invalid' end
    return Target.project_search(raw,book,hit.chapter_uid,row,format)
end

M.can_locate=Target.can_locate_search
M.resolve=Target.resolve_search
M.bind_file=Target.bind_search_file

return M
