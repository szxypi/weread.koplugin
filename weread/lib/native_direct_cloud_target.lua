-- Resolve a cloud chapter using the verified native catalog and account cache.
-- Downloads are local only; cloud progress is read before and after the work.
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local Cache=require('weread.lib.native_direct_cache')
local Catalog=require('weread.lib.native_book_catalog')
local Cloud=require('weread.lib.native_direct_cloud')
local Currentness=require('weread.lib.source_currentness')
local Crypto=require('weread.lib.crypto')
local Reader=require('weread.lib.native_direct_reader')
local Source=require('weread.lib.native_chapter_source')
local M={}
function M.resolve(client,settings,entry,file,context,native,web,current,wanted,book)
    local function active()
        local ok,value=pcall(current)
        return ok and value==true and Access.matches(settings,native) and Currentness.matches(settings,web)
    end
    if type(current)~='function' or not Cloud.valid_target(wanted) or type(entry)~='table'
        or wanted.book_id~=entry.book_id or wanted.chapter_uid==entry.chapter_uid
        or type(book)~='table' or book.book_id~=entry.book_id or type(native)~='table'
        or type(native.scope)~='table' or type(native.credentials)~='table'
        or native.scope.vid~=native.credentials.vid or not active() then return nil,'invalid' end
    local initial,why=Cloud.prepare(client,settings,entry,file,context,native,web,active)
    if not initial then return nil,why end
    if initial.relation~='other_chapter' or not Cloud.same_target(initial.target,wanted) then return nil,'cloud_changed' end
    local auth=Auth:new(client,{expected_vid=native.scope.vid,is_current=active})
    local ok,result=pcall(function()
        local model=Catalog.read(auth,native.credentials,entry.book_id,'native_catalog')
        local catalog=require('weread.ui.native_direct_reading').project(model,entry.book_id)
        if not catalog or catalog.version~=entry.book_version
            or entry.catalog_sha256 and entry.catalog_sha256~=catalog.reading_digest then return {error='catalog_changed'} end
        local chapter,ids,indexes=nil,0,0
        for _,row in ipairs(catalog.chapters) do
            if row.chapterUid==wanted.chapter_uid then chapter=row;ids=ids+1 end
            if row.chapterIdx==wanted.chapter_idx then indexes=indexes+1 end
        end
        if ids~=1 or indexes~=1 or not chapter or chapter.chapterIdx~=wanted.chapter_idx then return {error='catalog_changed'} end
        if not chapter.downloadable then return {error='not_entitled'} end
        local source,source_error=Source.fetch(client,settings,native,entry.book_id,wanted.chapter_uid,{is_current=active})
        if not source then return {error=source_error or 'unavailable'} end
        if source.is_text~=false or source.book_version~=catalog.version or source.reading_catalog_sha256~=catalog.reading_digest
            or type(source.body)~='string' or source.body=='' then return {error='source_changed'} end
        local digest=Crypto.sha256_hex(source.body)
        local rows=Cache.list(settings,native.scope.vid,entry.book_id,active,wanted.chapter_uid)
        if not rows then return {error='storage'} end
        local path,target_entry,reused
        for _,candidate in ipairs(rows) do
            if candidate.chapter_uid==wanted.chapter_uid and candidate.chapter_idx==wanted.chapter_idx
                and candidate.book_version==catalog.version and candidate.catalog_sha256==catalog.reading_digest
                and candidate.source_sha256==digest then
                local opened,checked=Cache.open(settings,native.scope.vid,entry.book_id,candidate,active,true)
                if opened then path=opened.path;target_entry=checked;reused=true;break end
            end
        end
        if not path then
            local expected={book_id=entry.book_id,chapter_uid=wanted.chapter_uid,book_version=catalog.version,
                reading_catalog_sha256=catalog.reading_digest,access_fingerprint=native.fingerprint}
            local built,build_error=Reader.build(client,settings,book,chapter,expected,{is_current=active,allow_missing_images=true})
            if not built then return {error=build_error or 'unavailable'} end
            if built.source_sha256~=digest or built.book_version~=catalog.version then return {error='source_changed'} end
            path=built.path;target_entry=Cache.identify(settings,native.scope.vid,path,active);reused=false
        end
        if not target_entry or not Cache.valid_entry(target_entry,entry.book_id,native.scope.vid)
            or target_entry.chapter_uid~=wanted.chapter_uid or target_entry.chapter_idx~=wanted.chapter_idx
            or target_entry.book_version~=catalog.version or target_entry.catalog_sha256~=catalog.reading_digest
            or target_entry.source_sha256~=digest or not active() then return {error='source_changed'} end
        -- Refuse to switch documents if this cloud coordinate cannot already
        -- be mapped to the exact target source. The new reader rechecks it.
        local destination,destination_error=Cloud.prepare_destination(client,settings,target_entry,path,native,web,active,wanted)
        if not destination then return {error=destination_error or 'target_unavailable'} end
        if not Cloud.same_target(destination.target,wanted) or type(destination.anchor)~='table'
            or destination.anchor.co~=wanted.chapter_offset then return {error='target_unavailable'} end
        local final,final_error=Cloud.prepare(client,settings,entry,file,context,native,web,active)
        if not final then return {error=final_error or 'unavailable'} end
        if final.relation~='other_chapter' or not Cloud.same_target(final.target,wanted) then return {error='cloud_changed'} end
        return {path=path,entry=target_entry,target=wanted,reused=reused}
    end)
    auth:cancel()
    if not ok then
        if not active() then return nil,'session_changed' end
        if result=='native_auth/native_catalog_info/http_401' or result=='native_auth/native_catalog_catalog/http_401' then return nil,'auth_expired' end
        if result=='native_auth/native_catalog_info/http_429' or result=='native_auth/native_catalog_catalog/http_429' then return nil,'rate_limited' end
        return nil,'unavailable'
    end
    if result.error then return nil,result.error end
    return result
end
return M
