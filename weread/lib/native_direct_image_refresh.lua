-- Rebuild only an improved copy of the currently verified native chapter.
-- The current file, local position and cloud state are never modified.
local Access=require('weread.lib.native_read_access')
local Cache=require('weread.lib.native_direct_cache')
local M={}
local function same(a,b)
    if not a or not b then return false end
    for _,key in ipairs({'book_id','chapter_uid','book_version','chapter_idx','key','copy','file_id',
        'source_sha256','missing_images','catalog_sha256','catalog_order','catalog_count','catalog_prev','catalog_next'}) do
        if a[key]~=b[key] then return false end
    end
    return true
end
function M.prepare(client,settings,selected,entry,current)
    local expected={book_id=entry.book_id,chapter_uid=entry.chapter_uid,book_version=entry.book_version,
        reading_catalog_sha256=entry.catalog_sha256,access_fingerprint=selected.fingerprint}
    local prepared,why=require('weread.lib.native_direct_source').fetch(client,settings,entry.book_id,entry.chapter_uid,
        expected,{is_current=current,allow_missing_images=true})
    if not prepared then return nil,why or 'unavailable' end
    if prepared.source_sha256~=entry.source_sha256 then return nil,'changed' end
    if prepared.missing_images>=entry.missing_images then return nil,'unchanged' end
    return prepared
end
function M.run(client,settings,selected,entry,path,book,current)
    if type(current)~='function' or not current() or not Access.matches(settings,selected)
        or not Cache.valid_entry(entry,entry and entry.book_id,selected and selected.scope and selected.scope.vid)
        or not entry.file_id or not entry.catalog_sha256 or entry.missing_images<1 then return {error='invalid'} end
    local function active() return current() and Access.matches(settings,selected) end
    local function source_current() return active() and same(Cache.identify(settings,selected.scope.vid,path,active),entry) end
    if not source_current() then return {error='changed'} end
    local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=selected.scope.vid,is_current=active})
    local ok,model=pcall(require('weread.lib.native_book_catalog').read,auth,selected.credentials,entry.book_id,'native_catalog')
    auth:cancel()
    if not ok then
        if model=='native_auth/native_catalog_info/http_401' or model=='native_auth/native_catalog_catalog/http_401' then return {error='auth_expired'} end
        if model=='native_auth/native_catalog_info/http_429' or model=='native_auth/native_catalog_catalog/http_429' then return {error='rate_limited'} end
        return {error='unavailable'}
    end
    local catalog=require('weread.ui.native_direct_reading').project(model,entry.book_id)
    local chapter=catalog and catalog.chapters[entry.catalog_order]
    if not catalog or catalog.version~=entry.book_version or catalog.reading_digest~=entry.catalog_sha256
        or #catalog.chapters~=entry.catalog_count or not chapter or not chapter.downloadable
        or chapter.chapterUid~=entry.chapter_uid or chapter.chapterIdx~=entry.chapter_idx
        or chapter.catalog_prev~=entry.catalog_prev or chapter.catalog_next~=entry.catalog_next then return {error='catalog_changed'} end
    local prepared,why=M.prepare(client,settings,selected,entry,active)
    if not prepared and why~='unchanged' then return {error=why} end
    if not source_current() then return {error='changed'} end
    if not prepared then return {kind='unchanged'} end
    local saved,reason=Cache.publish(settings,selected.scope.vid,book,chapter,prepared,active)
    if not saved then return {error=reason or 'storage'} end
    if not source_current() then return {error='changed'} end
    return {kind='improved',path=saved.path,book_version=saved.book_version,source_sha256=saved.source_sha256,
        missing_images=saved.missing_images}
end
return M
