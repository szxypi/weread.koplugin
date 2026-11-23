-- Worker-only source proof for a future native-chapter time transfer. This
-- does not select, collect, reserve, or send time. The caller must still bind
-- any eventual request to its independently checked ledger and cloud state.
local Cache=require('weread.lib.native_direct_cache')
local Position=require('weread.lib.native_direct_position')
local Source=require('weread.lib.readtime_source')
local Contract=require('weread.lib.readtime_transfer_contract')
local Account=require('weread.lib.native_position_contract').account_key
local Crypto=require('weread.lib.crypto')
local Identity=require('weread.lib.book_file_identity')
local M={}

-- A bounded page of account-owned cache metadata. Matching fingerprints are
-- independently opened and checked; ambiguous chapters are never guessed.
-- All pages must see the same inventory before a reference can be returned.
function M.scan_page(settings,account,scope,selection,cursor,prior,current,options)
    options=options or {};local cache=options.cache or Cache
    if not Contract.account(account) or type(scope)~='table' or Account(scope.vid)~=account
        or type(selection)~='table' or not Contract.id(selection.book_id) or not Contract.hash(selection.file_id)
        or not Contract.integer(selection.book_version,1,2147483647) or not Contract.integer(cursor,1,2001)
        or type(current)~='function' or current()~=true then return {kind='unavailable'} end
    local rows=cache.list(settings,scope.vid,selection.book_id,current)
    if not Contract.array(rows,0,2000) or cursor>#rows+1 then return {kind='unavailable'} end
    local stamp=Contract.digest(rows)
    if prior and (type(prior)~='table' or prior.stamp~=stamp) then return {kind='unavailable'} end
    local chosen=prior and prior.chosen or nil
    local last=math.min(cursor+31,#rows)
    for index=cursor,last do
        local entry=rows[index]
        if entry.book_version==selection.book_version and Contract.hash(entry.text_digest) then
            local book={book_id=selection.book_id,bookVersion=selection.book_version}
            local raw=Identity.encode(book,{{}},Identity.capture(book),entry.text_digest,selection.book_version)
            local identity=Identity.decode(raw)
            if identity and identity.file_id==selection.file_id then
                if not Contract.integer(entry.chapter_idx,0,1000000) then return {kind='unavailable'} end
                local opened=cache.open(settings,scope.vid,selection.book_id,entry,current)
                if not opened or opened.file_id~=selection.file_id or opened.book_version~=selection.book_version
                    or opened.source_sha256~=entry.source_sha256 then return {kind='unavailable'} end
                if chosen and (chosen.chapter_uid~=entry.chapter_uid or chosen.source_sha256~=entry.source_sha256) then
                    return {kind='ambiguous'}
                end
                chosen=chosen or {kind='native_direct',file=opened.path,chapter_uid=entry.chapter_uid,
                    source_sha256=entry.source_sha256}
            end
        end
    end
    if current()~=true then return {kind='unavailable'} end
    if last<#rows then return {kind='more',cursor=last+1,prior={stamp=stamp,chosen=chosen}} end
    return chosen and {kind='found',reference=chosen} or {kind='unavailable'}
end

function M.observe(client,settings,account,selection,file,native,web,current,previous)
    if not Contract.account(account) or type(native)~='table' or type(native.scope)~='table'
        or Account(native.scope.vid)~=account or type(selection)~='table'
        or not Contract.id(selection.book_id) or not Contract.hash(selection.file_id)
        or not Contract.integer(selection.book_version,1,2147483647)
        or type(file)~='string' or type(current)~='function' then return nil,'invalid' end
    local ok,entry=pcall(Cache.identify,settings,native.scope.vid,file,current)
    if not ok or not entry or entry.book_id~=selection.book_id or entry.file_id~=selection.file_id
        or entry.book_version~=selection.book_version then return nil,'file_changed' end
    local function verify_catalog(payload)
        assert(Source.version(payload,selection.book_id)==selection.book_version,'native_direct_time/version')
    end
    local raw,why,stamp=Position.verified_source(client,settings,entry,file,native,web,current,
        {verify_catalog=verify_catalog})
    if not raw then return nil,why end
    if not Contract.hash(stamp) or Crypto.sha256_hex(raw)~=entry.source_sha256 then return nil,'source_changed' end
    local result={kind='native_direct',ref={kind='native_direct',file=file,chapter_uid=entry.chapter_uid,
        source_sha256=entry.source_sha256},book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
        file_id=entry.file_id,book_version=entry.book_version,source_sha256=entry.source_sha256,
        catalog_stamp=stamp,account=account}
    if previous and Contract.digest(previous)~=Contract.digest(result) then return nil,'source_changed' end
    return result
end
return M
