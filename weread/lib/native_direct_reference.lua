-- Native chapter writes require independent native and Web verification.
-- Offline drafts may also use the pinned chapter's native-only source;
-- online submission must independently verify it against the Web source.
local Access=require('weread.lib.native_read_access')
local Currentness=require('weread.lib.source_currentness')
local Cache=require('weread.lib.native_direct_cache')
local Path=require('weread.lib.native_direct_path')
local Position=require('weread.lib.native_direct_position')
local Reference=require('weread.lib.selection_reference')
local M={}
local function active(settings,native,web,current)
    local ok,value=pcall(current)
    return ok and value==true and Access.matches(settings,native) and Currentness.matches(settings,web)
end
local function verified(client,settings,entry,file,native,web,current)
    local raw,why,_,_,format=Position.verified_source(client,settings,entry,file,native,web,current,{allow_txt=true})
    return raw,why,format
end
function M.capture(client,settings,entry,file,input,native,web,current,bookmark,library)
    if type(current)~='function' or not Path.contains(settings,file) or not active(settings,native,web,current) then return nil,'invalid' end
    local raw,why,format=verified(client,settings,entry,file,native,web,current)
    if not raw then return nil,why end
    local ref=bookmark and require('weread.lib.bookmark_reference') or Reference
    local row,reason=ref.capture_direct(input,entry,file,raw,format)
    if not active(settings,native,web,current) then return nil,'session_changed' end
    if row and library then
        -- A cache failure never prevents the already verified online action.
        pcall(function() require('weread.lib.native_direct_mark_source_store'):new(library):write(entry,raw,format) end)
    end
    if not active(settings,native,web,current) then return nil,'session_changed' end
    return row,reason
end
local function cached_source(library,pinned,file,live)
    if not live() then return nil,'session_changed' end
    local ok,raw,format=pcall(function() return require('weread.lib.native_direct_mark_source_store'):new(library):read(pinned) end)
    if not live() then return nil,'session_changed' end
    if not ok or not raw then
        ok,raw=pcall(Cache.read_raw_source,file,pinned)
        format='web_xhtml'
        if not ok or not raw then ok,raw=pcall(Cache.read_raw_source,file,pinned,'txt');format='web_txt' end
        if not live() then return nil,'session_changed' end
        if not ok or not raw then return nil,'offline_source_unavailable' end
    end
    return raw,nil,format
end
local function cached(settings,library,entry,file,native,web,current)
    if type(current)~='function' or not Path.contains(settings,file) or not active(settings,native,web,current)
        or type(native)~='table' or type(native.scope)~='table' or type(web)~='table' or type(web.web)~='table'
        or type(web.web.cookies)~='table' or web.web.cookies.wr_vid~=native.scope.vid then return nil,'invalid' end
    local function live() return active(settings,native,web,current) end
    local pinned=Cache.identify(settings,native.scope.vid,file,live)
    if type(pinned)~='table' or type(entry)~='table' then return nil,'source_changed' end
    for _,key in ipairs({'owner','book_id','chapter_uid','chapter_idx','book_version','key','copy','file_id','source_sha256'}) do
        if pinned[key]~=entry[key] then return nil,'source_changed' end
    end
    return cached_source(library,pinned,file,live)
end
function M.capture_cached(settings,library,entry,file,input,native,web,current)
    local raw,why,format=cached(settings,library,entry,file,native,web,current)
    if not raw then return nil,why end
    local row,reason=Reference.capture_direct(input,entry,file,raw,format)
    if not active(settings,native,web,current) then return nil,'session_changed' end
    return row,reason
end
function M.restore_cached(settings,library,entry,file,key,native,web,current)
    local raw,why,format=cached(settings,library,entry,file,native,web,current)
    if not raw then return nil,why end
    local row,reason=Reference.restore_direct(entry,file,key,raw,format)
    if not active(settings,native,web,current) then return nil,'session_changed' end
    return row,reason
end
-- A local draft can locate its original chapter without an open reader or
-- service credentials. The file receipt and raw source still have to match.
function M.restore_downloaded(settings,library,scope,book_id,key)
    local selection=Reference.parse(key)
    local function live() return settings:auth_scope_matches(scope) end
    if not selection or type(scope)~='table' or not live() then return nil end
    local entries=Cache.list(settings,scope.vid,book_id,live,selection.chapter_uid)
    for _,entry in ipairs(entries or {}) do
        if not live() then return nil end
        if entry.source_sha256==selection.raw_sha256 then
            local opened,pinned=Cache.open(settings,scope.vid,book_id,entry,live,true)
            if opened and pinned then
                local raw,_,format=cached_source(library,pinned,opened.path,live)
                local row=raw and Reference.restore_direct(pinned,opened.path,key,raw,format)
                if row and live() then return row,{path=opened.path,file_id=pinned.file_id} end
            end
        end
    end
end
function M.verify(client,settings,native,row,file,current,bookmark)
    if type(current)~='function' or not Path.contains(settings,file) or type(native)~='table'
        or type(native.scope)~='table' or not Access.matches(settings,native) then return nil,'invalid' end
    local web=Currentness.capture(settings)
    if not web or not web.web or not web.web.cookies or web.web.cookies.wr_vid~=native.scope.vid then return nil,'web_expired' end
    local function live() return active(settings,native,web,current) end
    if not live() then return nil,'session_changed' end
    local entry=Cache.identify(settings,native.scope.vid,file,live)
    if not entry or not live() then return nil,'source_changed' end
    local raw,why,format=verified(client,settings,entry,file,native,web,live)
    if not raw then return nil,why end
    local ref=bookmark and require('weread.lib.bookmark_reference') or Reference
    local checked,reason=ref.verify_direct(row,entry,file,raw,format)
    if not live() then return nil,'session_changed' end
    return checked,reason,entry.book_version,format
end
function M.restore(client,settings,entry,file,key,native,web,current,library)
    if type(current)~='function' or not Path.contains(settings,file) or not active(settings,native,web,current) then return nil,'invalid' end
    local raw,why,format=verified(client,settings,entry,file,native,web,current)
    if not raw then return nil,why end
    local row,reason=Reference.restore_direct(entry,file,key,raw,format)
    if not active(settings,native,web,current) then return nil,'session_changed' end
    if row and library then
        pcall(function() require('weread.lib.native_direct_mark_source_store'):new(library):write(entry,raw,format) end)
    end
    if not active(settings,native,web,current) then return nil,'session_changed' end
    return row,reason
end
return M
