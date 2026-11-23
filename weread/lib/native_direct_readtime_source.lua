-- Worker-only source proof for a future native-chapter time transfer. This
-- does not select, collect, reserve, or send time. The caller must still bind
-- any eventual request to its independently checked ledger and cloud state.
local Cache=require('weread.lib.native_direct_cache')
local Position=require('weread.lib.native_direct_position')
local Source=require('weread.lib.readtime_source')
local Contract=require('weread.lib.readtime_transfer_contract')
local Account=require('weread.lib.native_position_contract').account_key
local Crypto=require('weread.lib.crypto')
local M={}

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
    local result={book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
        file_id=entry.file_id,book_version=entry.book_version,source_sha256=entry.source_sha256,
        catalog_stamp=stamp,account=account}
    if previous and Contract.digest(previous)~=Contract.digest(result) then return nil,'source_changed' end
    return result
end
return M
