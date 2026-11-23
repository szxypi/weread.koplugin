-- Current native viewport -> independently verified original-source bookmark.
local Point=require('weread.lib.bookmark_point')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Currentness=require('weread.lib.source_currentness')
local Catalog=require('weread.lib.source_upload_candidate')
local Marks=require('weread.lib.my_cloud_marks')
local Protocol=require('weread.lib.protocol')
local Crypto=require('weread.lib.crypto')
local M={}
local function fail(reason) error('bookmark_reference/'..reason,0) end
local function key(uid,point,sha) return 'bookmark:'..uid..':'..point..':'..sha end
function M.valid(row,book)
    local source=type(row)=='table' and (Marks.id(book) and Currentness.expected(row.source) or Currentness.expected_cb(row.source))
    return source~=nil and Marks.display_id(book)==book and source.book_id==book and row.bookmark==true and row.type==0
        and Point.can_locate(row) and tostring(row.chapterUid)==source.chapter_uid and row.chapterIdx==source.chapter_idx
        and row.bookmarkId==key(source.chapter_uid,row.range,source.raw_sha256)
        and type(row.markText)=='string' and #row.markText>0 and #row.markText<=4096
        and Protocol.utf8_substr(row.markText,#row.markText)==row.markText
        and not row.markText:find('[%z\1-\8\11\12\14-\31\127]') or false
end
local function archive(file,book,uid,read)
    read=read or require('weread.lib.source_archive').read
    if type(file)~='string' or file=='' or #file>4096 or file:find('[%z%c]') then fail('file') end
    local data=read(file,{[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path(uid)]=Source.MAX_META_BYTES})
    local identity=data and Identity.decode(data[Identity.PATH]);local meta=data and data[Source.meta_path(uid)]
    local record=Source.decode_metadata(meta)
    if not identity or identity.book_id~=book or not record or record.book_id~=book or record.chapter_uid~=uid
        or record.file_id~=identity.file_id or record.format~='web_xhtml' and record.format~='web_txt' then fail('source') end
    local rawpath=Source.raw_path(record.raw_sha256)
    data=read(file,{[rawpath]=Source.MAX_BYTES,[record.render_path]=Source.MAX_RENDERED_BYTES,
        [Source.path_meta_path(record.render_path)]=Source.MAX_META_BYTES})
    if not data or data[Source.path_meta_path(record.render_path)]~=meta then fail('source') end
    local value=Source.verify_snapshot{metadata=meta,identity=identity,book_id=book,chapter_uid=uid,
        raw=data[rawpath],rendered=data[record.render_path]}
    if not value then fail('source') end
    return value.raw,record,meta
end
local function guarded(task)
    local ok,value=pcall(task)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^bookmark_reference/[a-z_]+$') and value or 'bookmark_reference/unavailable'
end
local function reference(book,uid,index,value)
    if index==nil then fail('catalog') end
    local row={bookmark=true,type=0,bookmarkId=key(uid,value.range,value.raw_sha256),range=value.range,chapterUid=tonumber(uid),chapterIdx=index,
        markText=value.markText,source={book_id=book,chapter_uid=uid,chapter_idx=index,raw_sha256=value.raw_sha256,raw_bytes=value.raw_bytes}}
    if not M.valid(row,book) then fail('reference') end;return row
end
function M.capture_native(input,read)
    return guarded(function()
        local captured=require('weread.lib.source_position_worker').capture(input,read)
        if not captured.position then fail('point') end
        local p=captured.position;local raw,record,meta=archive(input.file,p.book_id,p.chapter_uid,read)
        if meta~=input.metadata or record.raw_sha256~=p.raw_sha256 or p.basis~=Source.coordinate_basis(record.format) then fail('source') end
        local value=Point.project(raw,p.chapter_offset,record.format);if not value then fail('point') end
        return reference(p.book_id,p.chapter_uid,Catalog.chapter_index(input.chapters,p.chapter_uid),value)
    end)
end
-- The caller verifies native and Web bytes and the account-bound cache entry
-- before passing them here. Never infer a point from the preview alone.
local function direct_source(entry,file,raw)
    local function hash(value) return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$') end
    if type(entry)~='table' or not Marks.id(entry.book_id) or not Marks.id(entry.chapter_uid)
        or type(entry.chapter_idx)~='number' or entry.chapter_idx<0 or entry.chapter_idx>1000000 or entry.chapter_idx%1~=0
        or type(entry.book_version)~='number' or entry.book_version<0 or entry.book_version>2147483647 or entry.book_version%1~=0
        or not hash(entry.file_id) or not hash(entry.source_sha256) or type(file)~='string' or file==''
        or type(raw)~='string' or #raw<1 or #raw>Source.MAX_BYTES or Crypto.sha256_hex(raw)~=entry.source_sha256 then fail('source') end
end
function M.capture_direct(input,entry,file,raw)
    return guarded(function()
        direct_source(entry,file,raw)
        if type(input)~='table' or type(input.identity)~='table' or input.book_id~=entry.book_id
            or input.chapter_uid~=entry.chapter_uid or input.file~=file or input.metadata~=entry.file_id..entry.source_sha256
            or input.render_path~='OEBPS/text/chapter.xhtml' or input.identity.book_id~=entry.book_id
            or input.identity.file_id~=entry.file_id or input.identity.book_version~=entry.book_version then fail('source_changed') end
        local map=require('weread.lib.source_coordinates').build(raw,{allow_multiple_bodies=true})
        local co=map and require('weread.lib.source_position_worker').locate_verified_map(map,input.text,input.point_offset)
        local value=co and Point.project(raw,co,'web_xhtml')
        if not value then fail('point') end
        return reference(entry.book_id,entry.chapter_uid,entry.chapter_idx,value)
    end)
end
function M.verify_direct(row,entry,file,raw)
    return guarded(function()
        direct_source(entry,file,raw)
        if not M.valid(row,entry.book_id) or tostring(row.chapterUid)~=entry.chapter_uid
            or row.chapterIdx~=entry.chapter_idx or row.source.raw_sha256~=entry.source_sha256 or row.source.raw_bytes~=#raw then
            fail('source_changed')
        end
        local point=Point.from_mark(raw,entry.book_id,entry.chapter_uid,row,'web_xhtml')
        local value=point and Point.project(raw,point.chapter_offset,'web_xhtml')
        local rebuilt=value and reference(entry.book_id,entry.chapter_uid,entry.chapter_idx,value)
        if not rebuilt or rebuilt.bookmarkId~=row.bookmarkId or rebuilt.markText~=row.markText
            or rebuilt.range~=row.range then fail('source_changed') end
        return rebuilt
    end)
end
function M.verify(row,book,current_file,read)
    local result,reason=guarded(function()
        local id=type(book)=='table' and tostring(book.book_id or book.bookId or '')
        if not M.valid(row,id) or Catalog.chapter_index(book.chapters,row.source.chapter_uid)~=row.chapterIdx then fail('reference') end
        local seen={}
        for _i,file in ipairs({current_file or false,book.cached_chapters and book.cached_chapters[row.source.chapter_uid] or false,
            book.cached_full_book or false,book.cached_file or false}) do
            if type(file)=='string' and not seen[file] then
                seen[file]=true
                local ok,raw,record=pcall(archive,file,id,row.source.chapter_uid,read)
                if ok and record.raw_sha256==row.source.raw_sha256 then
                    local point=Point.from_mark(raw,id,row.source.chapter_uid,row,record.format)
                    local value=point and Point.project(raw,point.chapter_offset,record.format)
                    local rebuilt=value and reference(id,row.source.chapter_uid,row.chapterIdx,value)
                    if rebuilt and rebuilt.bookmarkId==row.bookmarkId and rebuilt.markText==row.markText
                        and value.raw_bytes==row.source.raw_bytes then return {row=rebuilt,format=record.format} end
                end
            end
        end
        fail('source_changed')
    end)
    if result then return result.row,result.format end
    return nil,reason
end
return M
