package.path='./?.lua;'..package.path
local Crypto=require('weread.lib.crypto')
local body='synthetic source';local stamp=string.rep('c',64)
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,file_id=string.rep('a',64),
    source_sha256=Crypto.sha256_hex(body)}
local live=true;local account=string.rep('d',20);local fetches=0;local version=7;local replaced=false
package.preload['weread.lib.native_position_contract']=function() return {account_key=function(vid)
    return vid=='123' and account or nil
end} end
package.preload['weread.lib.native_direct_cache']=function() return {identify=function(_,vid,file,current)
    assert(vid=='123' and file=='/synthetic.epub');return current() and not replaced and entry or nil
end} end
package.preload['weread.lib.native_direct_position']=function() return {verified_source=function(_,_,e,_,_,_,current,options)
    fetches=fetches+1
    if not current() then return nil,'invalid' end
    local ok=pcall(function() options.verify_catalog({bookId='42',bookVersion=version}) end)
    if not ok then return nil,'source_changed' end
    return e==entry and body or nil,nil,stamp
end} end
local TimeSource=require('weread.lib.native_direct_readtime_source')
local selection={book_id='42',file_id=entry.file_id,book_version=7}
local native={scope={vid='123'}};local function current() return live end
local function observe(previous)
    return TimeSource.observe({}, {},account,selection,'/synthetic.epub',native,{},current,previous)
end
local result=assert(observe())
assert(result.source_sha256==entry.source_sha256 and result.catalog_stamp==stamp and result.account==account)
assert(result.body==nil and result.file_id==selection.file_id and result.chapter_uid=='37')
assert(observe(result),'stable independent source was rejected')
version=8;local bad,reason=observe();assert(not bad and reason=='source_changed');version=7
selection.file_id=string.rep('b',64);bad,reason=observe();assert(not bad and reason=='file_changed')
selection.file_id=entry.file_id;selection.book_version=0;bad,reason=observe();assert(not bad and reason=='invalid')
selection.book_version=7;replaced=true;bad,reason=observe();assert(not bad and reason=='file_changed');replaced=false
local before=fetches
bad,reason=TimeSource.observe({}, {},string.rep('e',20),selection,'/synthetic.epub',native,{},current)
assert(not bad and reason=='invalid' and fetches==before,'wrong account reached source read')
live=false;bad,reason=observe();assert(not bad and reason=='file_changed');live=true
stamp=string.rep('e',64);bad,reason=observe(result);assert(not bad and reason=='source_changed')
stamp='invalid';bad,reason=observe();assert(not bad and reason=='source_changed')
print('PASS: native reading-time source proof is account, file and version bound')
