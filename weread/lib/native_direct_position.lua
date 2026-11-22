-- Read-only bridge between a native chapter, its visible reader anchor and the
-- same chapter's Web source. A byte match is not permission to upload.
local Cache=require('weread.lib.native_direct_cache')
local NativeAccess=require('weread.lib.native_read_access')
local NativeSource=require('weread.lib.native_chapter_source')
local Currentness=require('weread.lib.source_currentness')
local Coordinates=require('weread.lib.source_coordinates')
local Worker=require('weread.lib.source_position_worker')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.native_position_protocol')
local M={}
local function hash(value) return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil end
local fields={'book_id','chapter_uid','book_version','chapter_idx','source_sha256','key','copy','file_id',
    'catalog_sha256','catalog_order','catalog_count','catalog_prev','catalog_next'}
local function same(first,second)
    if type(first)~='table' or type(second)~='table' then return false end
    for _,key in ipairs(fields) do if first[key]~=second[key] then return false end end
    return true
end
M.same=same
function M.prepare(client,settings,entry,file,context,native,web,current,target_offset)
    local function active()
        local ok,value=pcall(current)
        return ok and value==true and NativeAccess.matches(settings,native) and Currentness.matches(settings,web)
    end
    if type(current)~='function' or type(native)~='table' or type(native.scope)~='table'
        or native.renewal_pending or type(web)~='table' or type(web.web)~='table'
        or type(web.web.cookies)~='table' or web.web.cookies.wr_vid~=native.scope.vid
        or not Cache.valid_entry(entry,entry and entry.book_id,native.scope.vid)
        or not hash(entry.file_id) or not Protocol.integer(entry.chapter_idx,0,1000000)
        or type(context)~='table' or type(context.text)~='string' or #context.text>Worker.MAX_CONTEXT_BYTES
        or not Protocol.integer(context.point_offset,0,Worker.MAX_CONTEXT_BYTES)
        or context.book_id~=entry.book_id or context.chapter_uid~=entry.chapter_uid
        or context.file~=file or type(context.identity)~='table' or context.identity.file_id~=entry.file_id
        or context.identity.book_id~=entry.book_id or context.identity.book_version~=entry.book_version
        or context.render_path~='OEBPS/text/chapter.xhtml'
        or target_offset~=nil and not Protocol.integer(target_offset,0,2147483647) or not active() then return nil,'invalid' end
    local ok,result=pcall(function()
        local first=Cache.identify(settings,native.scope.vid,file,active)
        if not same(first,entry) then return {error='file_changed'} end
        local source,why=NativeSource.fetch(client,settings,native,entry.book_id,entry.chapter_uid,{is_current=active})
        if not source then return {error=why or 'unavailable'} end
        if source.is_text~=false or source.book_version~=entry.book_version
            or source.reading_catalog_sha256~=entry.catalog_sha256 and entry.catalog_sha256~=nil
            or type(source.body)~='string' or #source.body<1 or #source.body>Coordinates.MAX_BYTES
            or Crypto.sha256_hex(source.body)~=entry.source_sha256 then return {error='source_changed'} end
        local expected=Currentness.expected{book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
            raw_sha256=entry.source_sha256,raw_bytes=#source.body}
        if not expected then return {error='invalid'} end
        local checked=Currentness.fetch(client,expected,web,'web_xhtml')
        if not Currentness.packet(checked,expected) or not active() then return {error='source_changed'} end
        local map=Coordinates.build(source.body,{format='web_xhtml',allow_multiple_bodies=true})
        if not map then return {error='source_unsupported'} end
        local offset=Worker.locate_verified_map(map,context.text,context.point_offset)
        if not Protocol.integer(offset,0,2147483647) then return {error='anchor_unavailable'} end
        local target
        if target_offset~=nil then
            target=map:anchor(target_offset,{segment_only=true}) or map:anchor(target_offset)
            local reverse=target and map:locate_point(target.text,target.point_offset)
            if not reverse or reverse.co~=target_offset then target=nil end
        end
        local later=Cache.identify(settings,native.scope.vid,file,active)
        if not same(later,entry) or not active() then return {error='file_changed'} end
        return {position={book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
            chapter_offset=offset,file_id=entry.file_id,book_version=entry.book_version,raw_sha256=entry.source_sha256,
            basis='filtered_xhtml_utf16',source_current=true,upload_verified=false},anchor=target}
    end)
    if not ok then
        if not active() then return nil,'session_changed' end
        if result=='source_currentness/web_expired' then return nil,'web_expired' end
        if result=='source_currentness/source_changed' or result=='source_currentness/catalog_changed' then return nil,'source_changed' end
        return nil,'unavailable'
    end
    if result.error then return nil,result.error end
    return result.position,nil,result.anchor
end
return M
