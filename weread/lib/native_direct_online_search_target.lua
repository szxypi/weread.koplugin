-- Worker-only bridge from an untrusted online search hit to a native chapter.
-- Both source channels and the account-bound EPUB must agree. Returned anchors
-- are local navigation only and never authorize progress or annotation writes.
local Access=require('weread.lib.native_read_access')
local Currentness=require('weread.lib.source_currentness')
local Cache=require('weread.lib.native_direct_cache')
local Position=require('weread.lib.native_direct_position')
local Target=require('weread.lib.book_search_target')
local Coordinates=require('weread.lib.source_coordinates')
local Crypto=require('weread.lib.crypto')
local Path=require('weread.lib.native_direct_path')
local Protocol=require('weread.lib.native_position_protocol')
local M={}

local function active(settings,native,web,current)
    local ok,value=pcall(current)
    return ok and value==true and Access.matches(settings,native) and Currentness.matches(settings,web)
end
local function same_anchor(map,offset)
    local anchor=map:anchor(offset,{segment_only=true}) or map:anchor(offset)
    local reverse=anchor and map:locate_point(anchor.text,anchor.point_offset)
    return reverse and reverse.co==offset and anchor or nil
end

function M.resolve(client,settings,source,file,hit,native,web,current,allow_download,book)
    local scope=type(native)=='table' and native.scope
    local row=type(source)=='table' and Target.row(source.book_id,hit)
    local uid=row and Protocol.id(row.chapterUid)
    if type(current)~='function' or type(scope)~='table' or type(scope.vid)~='string'
        or native.renewal_pending or type(native.credentials)~='table' or native.credentials.vid~=scope.vid
        or type(web)~='table' or type(web.web)~='table' or type(web.web.cookies)~='table'
        or web.web.cookies.wr_vid~=scope.vid
        or not Cache.valid_entry(source,source and source.book_id,scope.vid) or not source.catalog_sha256
        or not row or not uid or type(allow_download)~='boolean' or type(book)~='table' or book.book_id~=source.book_id
        or not active(settings,native,web,current) then return nil,'invalid' end
    local function live() return active(settings,native,web,current) end
    local function source_current()
        local initial=Cache.identify(settings,scope.vid,file,live)
        if Position.same(source,initial) and live() then return initial end
    end
    local ok,result=pcall(function()
        local original=source_current()
        if not original then return {error='source_changed'} end
        local function matches(entry)
            return Cache.valid_entry(entry,source.book_id,scope.vid) and entry.chapter_uid==uid
                and entry.book_version==source.book_version and entry.catalog_sha256==source.catalog_sha256
                and entry.catalog_count==source.catalog_count
        end
        local function prepare(pinned,path)
            if not pinned or not matches(pinned) or not Path.contains(settings,path) or not live() then return nil,'source_changed' end
            local raw,why,_,_,format=Position.verified_source(client,settings,pinned,path,native,web,live,{allow_txt=true})
            if not raw then return nil,why or 'unavailable' end
            if Crypto.sha256_hex(raw)~=pinned.source_sha256 then return nil,'source_changed' end
            if format~='web_xhtml' and format~='web_txt' then return nil,'source_changed' end
            local projected=Target.project(raw,source.book_id,hit,format)
            if not projected or projected.book_id~=source.book_id or projected.chapter_uid~=uid
                or projected.raw_sha256~=pinned.source_sha256 or projected.upload_verified~=false then
                return nil,'target_unavailable'
            end
            local map=Coordinates.build(raw,{format=format,allow_multiple_bodies=true,omit_initial_bom=true})
            local anchor=map and same_anchor(map,projected.chapter_offset)
            if not anchor then return nil,'target_unavailable' end
            local later=Cache.identify(settings,scope.vid,path,live)
            if not Position.same(pinned,later) or not source_current() then return nil,'source_changed' end
            return {path=path,entry=pinned,anchor=anchor,local_only=true},nil
        end
        if uid==source.chapter_uid then
            local resolved,why=prepare(original,file)
            return resolved or {error=why}
        end
        local rows=Cache.list(settings,scope.vid,source.book_id,live,uid)
        if not rows then return {error='storage'} end
        local failed
        for _,entry in ipairs(rows) do
            if matches(entry) then
                local opened,pinned=Cache.open(settings,scope.vid,source.book_id,entry,live,true)
                if opened then
                    local resolved,why=prepare(pinned,opened.path)
                    if resolved then resolved.reused=true;return resolved end
                    failed=why
                    if why=='auth_expired' or why=='web_expired' or why=='rate_limited' or why=='session_changed' then
                        return {error=why}
                    end
                end
            end
        end
        if not allow_download then return {error=failed or 'not_saved'} end
        local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=scope.vid,is_current=live})
        local succeeded,value=pcall(function()
            local model=require('weread.lib.native_book_catalog').read(auth,native.credentials,source.book_id,'native_catalog')
            local catalog=require('weread.ui.native_direct_reading').project(model,source.book_id)
            if not catalog or catalog.version~=source.book_version or catalog.reading_digest~=source.catalog_sha256
                or #catalog.chapters~=source.catalog_count then return {error='catalog_changed'} end
            local chapter
            for _,candidate in ipairs(catalog.chapters) do
                if candidate.chapterUid==uid then if chapter then return {error='catalog_changed'} end;chapter=candidate end
            end
            if not chapter then return {error='catalog_changed'} end
            if not chapter.downloadable then return {error='not_entitled'} end
            local expected={book_id=source.book_id,chapter_uid=uid,book_version=catalog.version,
                reading_catalog_sha256=catalog.reading_digest,access_fingerprint=native.fingerprint}
            local built,why=require('weread.lib.native_direct_reader').build(client,settings,book,chapter,expected,
                {is_current=live,allow_missing_images=true})
            if not built or not Path.contains(settings,built.path) or not live() then return {error=why or 'unavailable'} end
            local resolved,reason=prepare(built.saved_entry,built.path)
            if not resolved then return {error=reason or 'target_unavailable'} end
            resolved.reused=false;return resolved
        end)
        auth:cancel()
        if not succeeded then
            if value=='native_auth/native_catalog_info/http_401' or value=='native_auth/native_catalog_catalog/http_401' then
                return {error='auth_expired'}
            elseif value=='native_auth/native_catalog_info/http_429' or value=='native_auth/native_catalog_catalog/http_429' then
                return {error='rate_limited'}
            end
            return {error='unavailable'}
        end
        return value
    end)
    if not live() then return nil,'session_changed' end
    if not ok or type(result)~='table' then return nil,'unavailable' end
    if result.error then return nil,result.error end
    return result
end
return M
