-- Prepare a personal note's other native chapter before switching readers.
-- All work here runs in the background; only local, account-bound files and
-- a note that matches their independently verified source may be returned.
local Cache=require('weread.lib.native_direct_cache')
local Protocol=require('weread.lib.native_position_protocol')
local Path=require('weread.lib.native_direct_path')
local Contract=require('weread.lib.mark_edit_contract')
local Task=require('weread.lib.personal_mark_task')
local M={}

local function same_source(a,b)
    for _,key in ipairs({'book_id','chapter_uid','book_version','file_id','key','copy','source_sha256',
        'catalog_sha256','catalog_order','catalog_count','catalog_prev','catalog_next'}) do
        if a[key]~=b[key] then return false end
    end
    return true
end

function M.resolve(client,settings,library,source,file,book,row,online,current)
    local scope=settings:get_auth_scope()
    local uid=type(row)=='table' and Protocol.id(row.chapterUid)
    if not scope or type(current)~='function' or not settings:auth_scope_matches(scope)
        or not current() or not Cache.valid_entry(source,source and source.book_id,scope.vid)
        or type(book)~='table' or book.book_id~=source.book_id or type(row)~='table'
        or type(row.chapterUid)~='number' or not uid
        or uid==source.chapter_uid or type(online)~='boolean' then return nil,'invalid' end
    local function active() return current() and settings:auth_scope_matches(scope) end
    local initial=Cache.identify(settings,scope.vid,file,active)
    if not initial or not same_source(source,initial) then return nil,'source_changed' end
    -- A catalog identity binds chapters across versions. Older entries without
    -- this receipt must be reopened online before they can be used as a source.
    if not source.catalog_sha256 then return nil,'catalog_missing' end
    local function matches(candidate)
        return Cache.valid_entry(candidate,source.book_id,scope.vid)
            and candidate.chapter_uid==uid and candidate.book_version==source.book_version
            and candidate.catalog_sha256==source.catalog_sha256 and candidate.catalog_count==source.catalog_count
    end
    local function prepare(candidate)
        if not matches(candidate) or not active() then return nil end
        local opened=Cache.open(settings,scope.vid,source.book_id,candidate,active)
        if not opened or not Path.contains(settings,opened.path) then return nil end
        local pinned=Cache.identify(settings,scope.vid,opened.path,active)
        if not pinned or not matches(pinned) or pinned.key~=candidate.key or pinned.copy~=candidate.copy then return nil end
        local metadata=pinned.file_id..pinned.source_sha256..pinned.key
        local ok,value=pcall(Task.prepare_direct,client,settings,library,opened.path,pinned,metadata,{row},online)
        local item=ok and type(value)=='table' and value.metadata==metadata and type(value.rows)=='table'
            and #value.rows==1 and value.rows[1]
        if type(item)~='table' or item.bookmarkId~=row.bookmarkId
            or item.reference_hash~=Contract.row_hash(row) or item.bookmark~=(row.type==0 and true or nil)
            or not active() then return nil end
        return {path=opened.path,entry=pinned}
    end
    local rows=Cache.list(settings,scope.vid,source.book_id,active)
    if not rows then return nil,'storage' end
    local choices,digest={},nil
    for _,candidate in ipairs(rows) do
        if matches(candidate) then
            if digest and digest~=candidate.source_sha256 then return nil,'ambiguous' end
            digest=candidate.source_sha256;choices[#choices+1]=candidate
        end
    end
    for _,candidate in ipairs(choices) do
        local result=prepare(candidate)
        if result then return result end
    end
    if not online then return nil,'not_saved' end
    local Access=require('weread.lib.native_read_access')
    local native=Access.capture(settings)
    if not native or native.renewal_pending or not native.scope or native.scope.vid~=scope.vid
        or not Access.matches(settings,native) then return nil,'auth_expired' end
    local function online_active() return active() and Access.matches(settings,native) end
    local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=scope.vid,is_current=online_active})
    local ok,result=pcall(function()
        local model=require('weread.lib.native_book_catalog').read(auth,native.credentials,source.book_id,'native_catalog')
        local catalog=require('weread.ui.native_direct_reading').project(model,source.book_id)
        if not catalog or catalog.version~=source.book_version or catalog.reading_digest~=source.catalog_sha256
            or #catalog.chapters~=source.catalog_count then return {error='catalog_changed'} end
        local chapter
        for _,candidate in ipairs(catalog.chapters) do if candidate.chapterUid==uid then chapter=candidate end end
        if not chapter then return {error='catalog_changed'} end
        if not chapter.downloadable then return {error='not_entitled'} end
        local expected={book_id=source.book_id,chapter_uid=uid,book_version=catalog.version,
            reading_catalog_sha256=catalog.reading_digest,access_fingerprint=native.fingerprint}
        local built,why=require('weread.lib.native_direct_reader').build(client,settings,book,chapter,expected,
            {is_current=online_active,allow_missing_images=true})
        if not built or not Path.contains(settings,built.path) or not online_active() then return {error=why or 'unavailable'} end
        local target=Cache.identify(settings,scope.vid,built.path,online_active)
        local prepared=target and prepare(target)
        return prepared or {error='target_unavailable'}
    end)
    auth:cancel()
    if not ok then
        if result=='native_auth/native_catalog_info/http_401' or result=='native_auth/native_catalog_catalog/http_401' then
            return nil,'auth_expired'
        end
        if result=='native_auth/native_catalog_info/http_429' or result=='native_auth/native_catalog_catalog/http_429' then
            return nil,'rate_limited'
        end
        return nil,'unavailable'
    end
    if not online_active() then return nil,'session_changed' end
    if result.error then return nil,result.error end
    return result
end
return M
