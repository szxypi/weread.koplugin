-- Prepare a local-only search hit for the same text point in an improved copy.
-- This never derives cloud coordinates or writes either chapter.
local Cache=require('weread.lib.native_direct_cache')
local Position=require('weread.lib.native_direct_position')
local Coordinates=require('weread.lib.source_coordinates')
local Worker=require('weread.lib.source_position_worker')
local Search=require('weread.lib.native_direct_search')
local Archive=require('weread.lib.source_archive')
local M={}
local RENDER='OEBPS/text/chapter.xhtml'
local function suffix(context)
    if type(context.text)~='string' or type(context.point_offset)~='number' or context.point_offset<0
        or context.point_offset%1~=0 then return nil end
    local chars,seen,bytes={},0,0
    for char in context.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        seen=seen+1
        if seen>context.point_offset then
            if #chars>=40 or bytes+#char>160 then break end
            chars[#chars+1]=char;bytes=bytes+#char
        end
    end
    return #chars>=12 and table.concat(chars) or nil
end
function M.prepare(settings,account,source,path,destination,context,current)
    if type(current)~='function' or not current() or type(source)~='table' or type(context)~='table'
        or context.file~=path or context.book_id~=source.book_id or context.chapter_uid~=source.chapter_uid
        or context.render_path~=RENDER or type(context.identity)~='table' or context.identity.file_id~=source.file_id
        or context.identity.book_version~=source.book_version or context.identity.book_id~=source.book_id
        or type(destination)~='string' or destination==path then return {error='invalid'} end
    local function original()
        return current() and Position.same(Cache.identify(settings,account,path,current),source)
    end
    if not original() then return {error='changed'} end
    local target=Cache.identify(settings,account,destination,current)
    if not target or target.book_id~=source.book_id or target.chapter_uid~=source.chapter_uid
        or target.book_version~=source.book_version or target.source_sha256~=source.source_sha256
        or target.missing_images>=source.missing_images or not target.file_id then return {error='changed'} end
    local saved=Cache.open(settings,account,source.book_id,target,current)
    if not saved or saved.path~=destination or saved.file_id~=target.file_id then return {error='changed'} end
    local raw=Archive.read(destination,{[RENDER]=Coordinates.MAX_BYTES})
    local map=raw and Coordinates.build(raw[RENDER],{format='web_xhtml'})
    local co=map and Worker.locate_verified_map(map,context.text,context.point_offset)
    local keyword=suffix(context)
    if not co or not keyword then return {error='unmatched'} end
    local results=Search.scan(settings,account,target,keyword,1,false,current)
    local hit
    local candidates=type(results)=='table' and type(results.hits)=='table' and results.hits or {}
    for _,candidate in ipairs(candidates) do
        if candidate.anchor and candidate.anchor.co==co then
            if hit then return {error='ambiguous'} end
            hit=candidate
        end
    end
    if not hit or hit.file_id~=target.file_id or not original() then return {error='unmatched'} end
    local fresh=Cache.identify(settings,account,destination,current)
    if not fresh or not Position.same(fresh,target) then return {error='changed'} end
    return {entry=target,hit=hit,keyword=keyword}
end
return M
