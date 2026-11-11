-- Own quoted thoughts use the raw-range semantics independently verified by
-- verify_my_thought_target.py. Reuse the verified archive/DOM binding, never
-- a thought's prose, an unrelated highlight, or the range as reading offset.
local Target=require('weread.lib.my_mark_target')
local Data=require('weread.lib.my_cloud_marks')
local Protocol=require('weread.lib.protocol')
local Dom=require('weread.lib.source_dom')
local M={}
local function text(value,max)
    return type(value)=='string' and #value>0 and #value<=max and not value:find('[%z\1-\8\11-\31\127]')
        and Protocol.utf8_substr(value,#value)==value
end
local function key(value) return text(value,256) and Dom.normalize(value)==value end
local function mark(row)
    return {type=row.type,chapterUid=row.chapterUid,markText=row.abstract,range=row.range}
end
function M.can_locate(row)
    return type(row)=='table' and key(row.reviewId) and type(row.abstract)=='string'
        and #row.abstract<=65536 and Target.can_locate(mark(row))
end
local function reference(book,chapter,row)
    if not Data.id(book) or not Data.id(chapter) or type(row)~='table' or not key(row.reviewId)
        or row.type~=1 or type(row.chapterUid)~='number' or row.chapterUid<1 or row.chapterUid>2147483647
        or row.chapterUid%1~=0 or tostring(row.chapterUid)~=chapter
        or row.bookId~=nil and tostring(row.bookId)~=book then return nil,'my_thought_target/scope' end
    if not text(row.abstract,65536) or Dom.normalize(row.abstract)=='' then return nil,'my_thought_target/quote' end
    if not Target.can_locate(mark(row)) then return nil,'my_thought_target/range' end
    local out=mark(row);out.bookId=book;return out
end
function M.project(raw,book,chapter,row)
    local value,reason=reference(book,chapter,row)
    if not value then return nil,reason end
    return Target.project(raw,book,chapter,value)
end
function M.bind_file(file,book,row,request_id,read_archive)
    local value,reason=reference(book,type(row)=='table' and tostring(row.chapterUid),row)
    if not value then return {error=reason,request_id=request_id} end
    return Target.bind_file(file,book,value,request_id,read_archive)
end
function M.resolve(book,current_file,row,request_id,read_archive)
    local id=type(book)=='table' and tostring(book.book_id or book.bookId or '')
    local value,reason=reference(id,type(row)=='table' and tostring(row.chapterUid),row)
    if not value then return {error=reason,request_id=request_id} end
    return Target.resolve(book,current_file,value,request_id,read_archive)
end
return M
