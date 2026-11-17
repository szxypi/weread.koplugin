-- Local-search results carry only a source offset and archive fingerprints.
-- They are rebound to the exact downloaded file before native navigation.
local Access=require('weread.lib.read_access')
local Cache=require('weread.lib.cached_book_search')
local Cloud=require('weread.lib.source_cloud')
local Source=require('weread.lib.position_source')
local M={}

local function hash(value)
    return type(value)=='string' and #value==64 and value:match('^[0-9a-f]+$')~=nil
end
local function number(value,maximum)
    return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=maximum
end
function M.row(book,keyword,hit)
    if type(book)~='string' or not Access.display_book_id(book) or type(keyword)~='string'
        or keyword=='' or #keyword>160 or type(hit)~='table' then return nil end
    local uid=Access.book_id(hit.chapter_uid);local chapter=uid and tonumber(uid)
    if not chapter or chapter>2147483647 or not number(hit.offset,Source.MAX_BYTES*8)
        or not hash(hit.source_hash) or not hash(hit.file_id) or not hash(hit.metadata_hash) then return nil end
    return {type=1,bookId=book,chapterUid=chapter,markText=keyword,range=string.format('%.0f',hit.offset),
        abstract=hit.source_hash,bookmarkId=hit.file_id,reviewId=hit.metadata_hash}
end
function M.can_locate(row)
    if type(row)~='table' or row.type~=1 or type(row.bookId)~='string' or not Access.display_book_id(row.bookId)
        or not number(row.chapterUid,2147483647) or row.chapterUid==0 or type(row.markText)~='string'
        or row.markText=='' or #row.markText>160 or type(row.range)~='string' or not row.range:match('^%d+$')
        or #row.range>10 or not number(tonumber(row.range),Source.MAX_BYTES*8)
        or not hash(row.abstract) or not hash(row.bookmarkId) or not hash(row.reviewId) then return false end
    return true
end
function M.bind_file(file,book,row,request_id,read_archive)
    if not M.can_locate(row) or row.bookId~=book then return {error='cached_search/scope',request_id=request_id} end
    local uid=tostring(row.chapterUid)
    local snapshot=Cache.snapshot(file,book,uid,read_archive)
    if not snapshot or snapshot.identity.file_id~=row.bookmarkId or snapshot.metadata_hash~=row.reviewId
        or snapshot.record.raw_sha256~=row.abstract then return {error='cached_search/source_changed',request_id=request_id} end
    local remote={book_id=book,chapter_uid=uid,chapter_offset=tonumber(row.range),raw_sha256=snapshot.record.raw_sha256,
        raw_bytes=snapshot.record.raw_bytes,basis=Source.coordinate_basis(snapshot.record.format),upload_verified=false}
    local bound=Cloud.bind({file=file,identity=snapshot.identity,book_id=book,request_id=request_id},remote,read_archive)
    if not bound.position or bound.metadata~=snapshot.metadata then return {error='cached_search/source_changed',request_id=request_id} end
    bound.file,bound.identity=file,snapshot.identity
    return bound
end
function M.resolve(book,current_file,row,request_id,read_archive)
    if type(book)~='table' or not M.can_locate(row) then return {error='cached_search/scope',request_id=request_id} end
    local id=tostring(book.book_id or book.bookId or '')
    if id~=row.bookId then return {error='cached_search/scope',request_id=request_id} end
    local uid=tostring(row.chapterUid);local seen={}
    local mapped=type(book.cached_chapters)=='table' and (book.cached_chapters[uid] or book.cached_chapters[tonumber(uid)])
    for _i,file in ipairs({current_file or false,mapped or false,
        book.cached_full_book or false,book.cached_file or false}) do
        if type(file)=='string' and not seen[file] then
            seen[file]=true
            local result=M.bind_file(file,id,row,request_id,read_archive)
            if result.position then return result end
        end
    end
    return {error='cached_search/source_unavailable',request_id=request_id}
end
return M
