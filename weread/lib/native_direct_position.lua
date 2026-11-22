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
local function source_map(client,settings,entry,file,native,web,active,options)
    local first=Cache.identify(settings,native.scope.vid,file,active)
    if not same(first,entry) then return nil,'file_changed' end
    local source,why=NativeSource.fetch(client,settings,native,entry.book_id,entry.chapter_uid,{is_current=active})
    if not source then return nil,why or 'unavailable' end
    if source.is_text~=false or source.book_version~=entry.book_version
        or source.reading_catalog_sha256~=entry.catalog_sha256 and entry.catalog_sha256~=nil
        or type(source.body)~='string' or #source.body<1 or #source.body>Coordinates.MAX_BYTES
        or Crypto.sha256_hex(source.body)~=entry.source_sha256 then return nil,'source_changed' end
    local expected=Currentness.expected{book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
        raw_sha256=entry.source_sha256,raw_bytes=#source.body}
    if not expected then return nil,'invalid' end
    local checked=Currentness.fetch(client,expected,web,'web_xhtml',options)
    if not Currentness.packet(checked,expected) or not active() then return nil,'source_changed' end
    local map=Coordinates.build(source.body,{format='web_xhtml',allow_multiple_bodies=true})
    if not map then return nil,'source_unsupported' end
    return map
end
local function target_anchor(map,offset)
    local anchor=map:anchor(offset,{segment_only=true}) or map:anchor(offset)
    local reverse=anchor and map:locate_point(anchor.text,anchor.point_offset)
    return reverse and reverse.co==offset and anchor or nil
end
function M.prepare(client,settings,entry,file,context,native,web,current,target_offset,options)
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
        local map,why=source_map(client,settings,entry,file,native,web,active,options)
        if not map then return {error=why} end
        local offset=Worker.locate_verified_map(map,context.text,context.point_offset)
        if not Protocol.integer(offset,0,2147483647) then return {error='anchor_unavailable'} end
        local target
        if target_offset~=nil then
            target=target_anchor(map,target_offset)
        end
        local summary
        if options and options.prepare_summary then
            local anchor=map:anchor(offset)
            if not anchor or type(anchor.text)~='string' or not Protocol.integer(anchor.point_offset,0,Worker.MAX_CONTEXT_BYTES) then
                return {error='summary_unavailable'}
            end
            local chars,excerpt={},{}
            for char in anchor.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars+1]=char end
            for index=anchor.point_offset+1,math.min(#chars,anchor.point_offset+20) do excerpt[#excerpt+1]=chars[index] end
            summary=table.concat(excerpt)
            if not Protocol.summary(summary) or summary:find('[%z%c]')
                or require('weread.lib.source_dom').normalize(summary)~=summary then return {error='summary_unavailable'} end
        end
        local later=Cache.identify(settings,native.scope.vid,file,active)
        if not same(later,entry) or not active() then return {error='file_changed'} end
        return {position={book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
            chapter_offset=offset,file_id=entry.file_id,book_version=entry.book_version,raw_sha256=entry.source_sha256,
            basis='filtered_xhtml_utf16',source_current=true,upload_verified=false},anchor=target,summary=summary}
    end)
    if not ok then
        if not active() then return nil,'session_changed' end
        if result=='source_currentness/web_expired' then return nil,'web_expired' end
        if result=='source_currentness/source_changed' or result=='source_currentness/catalog_changed' then return nil,'source_changed' end
        if result=='source_currentness/remote_changed' then return nil,'cloud_changed' end
        return nil,'unavailable'
    end
    if result.error then return nil,result.error end
    return result.position,nil,result.anchor,result.summary
end
-- Prepare a cloud target without assuming that the newly opened viewport has
-- selectable text. The caller still owns page and account lifetime checks.
function M.prepare_target(client,settings,entry,file,native,web,current,offset)
    local function active()
        local ok,value=pcall(current)
        return ok and value==true and NativeAccess.matches(settings,native) and Currentness.matches(settings,web)
    end
    if type(current)~='function' or type(native)~='table' or type(native.scope)~='table' or native.renewal_pending
        or type(web)~='table' or type(web.web)~='table' or type(web.web.cookies)~='table'
        or web.web.cookies.wr_vid~=native.scope.vid or not Cache.valid_entry(entry,entry and entry.book_id,native.scope.vid)
        or not hash(entry.file_id) or not Protocol.integer(entry.chapter_idx,0,1000000)
        or not Protocol.integer(offset,0,2147483647) or not active() then return nil,'invalid' end
    local ok,result=pcall(function()
        local map,why=source_map(client,settings,entry,file,native,web,active)
        if not map then return {error=why} end
        local anchor=target_anchor(map,offset)
        if not anchor then return {error='target_unavailable'} end
        local later=Cache.identify(settings,native.scope.vid,file,active)
        if not same(later,entry) or not active() then return {error='file_changed'} end
        return {anchor=anchor}
    end)
    if not ok then
        if not active() then return nil,'session_changed' end
        if result=='source_currentness/web_expired' then return nil,'web_expired' end
        if result=='source_currentness/source_changed' or result=='source_currentness/catalog_changed' then return nil,'source_changed' end
        return nil,'unavailable'
    end
    if result.error then return nil,result.error end
    return result.anchor
end
return M
