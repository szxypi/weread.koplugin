-- Current native viewport -> independently verified original-source bookmark.
local Point=require('weread.lib.bookmark_point')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Currentness=require('weread.lib.source_currentness')
local Catalog=require('weread.lib.source_upload_candidate')
local Marks=require('weread.lib.my_cloud_marks')
local Protocol=require('weread.lib.protocol')
local M={}
local function fail(reason) error('bookmark_reference/'..reason,0) end
local function key(uid,point,sha) return 'bookmark:'..uid..':'..point..':'..sha end
function M.valid(row,book)
    local source=type(row)=='table' and Currentness.expected(row.source)
    return source~=nil and Marks.id(book)==book and source.book_id==book and row.bookmark==true and row.type==0
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
        or record.file_id~=identity.file_id or record.format~='web_xhtml' then fail('source') end
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
        if not captured.position or captured.position.basis~='filtered_xhtml_utf16' then fail('point') end
        local p=captured.position;local raw,record,meta=archive(input.file,p.book_id,p.chapter_uid,read)
        if meta~=input.metadata or record.raw_sha256~=p.raw_sha256 then fail('source') end
        local value=Point.project(raw,p.chapter_offset);if not value then fail('point') end
        return reference(p.book_id,p.chapter_uid,Catalog.chapter_index(input.chapters,p.chapter_uid),value)
    end)
end
function M.verify(row,book,current_file,read)
    return guarded(function()
        local id=type(book)=='table' and tostring(book.book_id or book.bookId or '')
        if not M.valid(row,id) or Catalog.chapter_index(book.chapters,row.source.chapter_uid)~=row.chapterIdx then fail('reference') end
        local seen={}
        for _i,file in ipairs({current_file or false,book.cached_chapters and book.cached_chapters[row.source.chapter_uid] or false,
            book.cached_full_book or false,book.cached_file or false}) do
            if type(file)=='string' and not seen[file] then
                seen[file]=true
                local ok,raw,record=pcall(archive,file,id,row.source.chapter_uid,read)
                if ok and record.raw_sha256==row.source.raw_sha256 then
                    local point=Point.from_mark(raw,id,row.source.chapter_uid,row)
                    local value=point and Point.project(raw,point.chapter_offset)
                    local rebuilt=value and reference(id,row.source.chapter_uid,row.chapterIdx,value)
                    if rebuilt and rebuilt.bookmarkId==row.bookmarkId and rebuilt.markText==row.markText
                        and value.raw_bytes==row.source.raw_bytes then return rebuilt end
                end
            end
        end
        fail('source_changed')
    end)
end
return M
