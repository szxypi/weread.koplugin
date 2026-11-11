-- Worker-only cache/network reads, exact archive preparation and full native
-- quotation verification. The reader owns its DOM and only exchanges pipes.
local Marks=require('weread.lib.my_cloud_marks')
local Cache=require('weread.lib.my_cloud_marks_store')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Dom=require('weread.lib.source_dom')
local Span=require('weread.lib.my_mark_span')
local Contract=require('weread.lib.mark_edit_contract')
local M={BATCH=8,MAX_NATIVE_BYTES=512*1024}
function M.load(client,library,book,access,online)
    local store=Cache:new(library,client);local saved=store:read(book)
    if online and access and not access.renewal_pending then
        local ok,value=pcall(Marks.fetch,client,book,{native=access})
        if ok then return {snapshot=value,refreshed=true} end
    end
    return {snapshot=saved or false,refreshed=false}
end
function M.prepare(file,book,metadata,rows,read)
    local record=Source.decode_metadata(metadata)
    if not record or record.book_id~=book or record.format~='web_xhtml' or type(rows)~='table' or #rows>M.BATCH then error('personal_marks/scope',0) end
    read=read or require('weread.lib.source_archive').read
    local wanted={[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path(record.chapter_uid)]=Source.MAX_META_BYTES,
        [Source.path_meta_path(record.render_path)]=Source.MAX_META_BYTES,[Source.raw_path(record.raw_sha256)]=Source.MAX_BYTES,
        [record.render_path]=Source.MAX_RENDERED_BYTES}
    local members=read(file,wanted);local identity=members and Identity.decode(members[Identity.PATH])
    if not identity or identity.book_id~=book or members[Source.meta_path(record.chapter_uid)]~=metadata
        or members[Source.path_meta_path(record.render_path)]~=metadata then error('personal_marks/source',0) end
    local verified=Source.verify_snapshot{metadata=metadata,identity=identity,book_id=book,chapter_uid=record.chapter_uid,
        raw=members[Source.raw_path(record.raw_sha256)],rendered=members[record.render_path]}
    if not verified then error('personal_marks/source',0) end
    local result={metadata=metadata,rows={}}
    for _i,row in ipairs(rows) do
        local span=Span.prepare(verified.raw,book,record.chapter_uid,row)
        if span then
            result.rows[#result.rows+1]={bookmarkId=row.bookmarkId,reference_hash=Contract.row_hash(row),
                first_anchor=span.first_anchor,last_anchor=span.last_anchor,normalized_sha256=span.normalized_sha256}
        end
    end
    return result
end
function M.verify(rows)
    if type(rows)~='table' or #rows>M.BATCH then return {} end
    local output={}
    for _i,row in ipairs(rows) do
        if type(row.text)=='string' and #row.text<=M.MAX_NATIVE_BYTES then
            local text=Dom.normalize(row.text)
            if text and text~='' and Crypto.sha256_hex(text)==row.normalized_sha256 then output[#output+1]=row.bookmarkId end
        end
    end
    return output
end
return M
