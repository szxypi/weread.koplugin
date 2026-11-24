-- Worker-only cache/network reads, exact archive preparation and full native
-- quotation verification. The reader owns its DOM and only exchanges pipes.
local Marks=require('weread.lib.my_cloud_marks')
local Cache=require('weread.lib.my_cloud_marks_store')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Dom=require('weread.lib.source_dom')
local Span=require('weread.lib.my_mark_span')
local Point=require('weread.lib.bookmark_point')
local Contract=require('weread.lib.mark_edit_contract')
local M={BATCH=Span.MAX_BATCH,MAX_NATIVE_BYTES=512*1024}
function M.load(client,library,book,access,online)
    local store=Cache:new(library,client);local saved=store:read(book)
    if online and access and not access.renewal_pending then
        local ok,value=pcall(Marks.fetch,client,book,{native=access})
        if ok then return {snapshot=value,refreshed=true} end
    end
    return {snapshot=saved or false,refreshed=false}
end
-- Thoughts have their own account-scoped snapshot and may fail independently
-- from marks. A partial or invalid network response never replaces the cache.
function M.load_thoughts(client,library,book,access,online)
    local thoughts=require('weread.lib.my_cloud_thoughts')
    local store=Cache:new(library,client,'thoughts');local saved=store:read(book)
    if online and access and not access.renewal_pending then
        local ok,value=pcall(thoughts.fetch,client,book,{native=access})
        if ok then return {snapshot=value,refreshed=true} end
    end
    return {snapshot=saved or false,refreshed=false}
end
local function project_rows(raw,book,uid,format,metadata,rows)
    local result={metadata=metadata,rows={}}
    local spans=Span.prepare_batch(raw,book,uid,rows,format)
    if not spans then error('personal_marks/scope',0) end
    for index,row in ipairs(rows) do
        if row.type==0 then
            local point=Point.prepare(raw,book,uid,row,format)
            if point then
                result.rows[#result.rows+1]={bookmarkId=row.bookmarkId,reference_hash=Contract.row_hash(row),bookmark=true,anchor=point.anchor}
            end
        elseif row.type==1 then
            local span=spans[index]
            if span then
                result.rows[#result.rows+1]={bookmarkId=row.bookmarkId,reference_hash=Contract.row_hash(row),
                    first_anchor=span.first_anchor,last_anchor=span.last_anchor,normalized_sha256=span.normalized_sha256}
            end
        end
    end
    return result
end
function M.prepare(file,book,metadata,rows,read)
    local record=Source.decode_metadata(metadata)
    if not record or record.book_id~=book or record.format~='web_xhtml' and record.format~='web_txt'
        or type(rows)~='table' or #rows>M.BATCH then error('personal_marks/scope',0) end
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
    return project_rows(verified.raw,book,record.chapter_uid,record.format,metadata,rows)
end
-- A direct chapter has no Web archive metadata. Its pinned cache entry was
-- verified by the reader worker; uncached bytes require both source channels.
function M.prepare_direct(client,settings,library,file,entry,metadata,rows,online)
    local DirectCache=require('weread.lib.native_direct_cache')
    local scope=settings:get_auth_scope()
    if not scope or not settings:auth_scope_matches(scope) or not DirectCache.valid_entry(entry,entry and entry.book_id,scope.vid)
        or type(entry.file_id)~='string' or #entry.file_id~=64 or not entry.file_id:match('^[a-f0-9]+$')
        or metadata~=entry.file_id..entry.source_sha256..entry.key or type(rows)~='table' or #rows>M.BATCH then
        error('personal_marks/scope',0)
    end
    local store=require('weread.lib.native_direct_mark_source_store'):new(library)
    local raw=store:read(entry)
    if not raw and (type(online)=='function' and online() or online==true) then
        local access=require('weread.lib.native_read_access').capture(settings)
        local web=require('weread.lib.source_currentness').capture(settings)
        if access and web then
            raw=require('weread.lib.native_direct_position').verified_source(client,settings,entry,file,access,web,function()
                return settings:auth_scope_matches(scope)
            end)
            if raw then store:write(entry,raw) end
        end
    end
    if not raw or not settings:auth_scope_matches(scope) then error('personal_marks/source',0) end
    return project_rows(raw,entry.book_id,entry.chapter_uid,'web_xhtml',metadata,rows)
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
