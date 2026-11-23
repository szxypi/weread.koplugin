package.path='./?.lua;'..package.path
local Crypto=require('weread.lib.crypto')
local body='synthetic source';local stamp=string.rep('c',64)
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,file_id=string.rep('a',64),
    source_sha256=Crypto.sha256_hex(body)}
local live=true;local account=string.rep('d',20);local fetches=0;local version=7;local replaced=false;local resolved_index=2
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
    return e==entry and body or nil,nil,stamp,e.chapter_idx or resolved_index
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
entry.chapter_idx=nil;local resolved=assert(observe())
assert(resolved.chapter_idx==2 and entry.chapter_idx==nil,'resolved index modified the cached chapter')
resolved_index=3;local moved,why=observe(resolved)
assert(not moved and why=='source_changed','changed resolved index was accepted');resolved_index=2
entry.chapter_idx=2
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
-- Search all inventory pages; identical file IDs in different chapters are
-- ambiguous even when both files individually verify.
local Identity=require('weread.lib.book_file_identity')
local book={book_id='42',bookVersion=7};local digest=string.rep('f',64)
local actual=assert(Identity.decode(Identity.encode(book,{{}},Identity.capture(book),digest,7)))
local wanted={book_id='42',file_id=actual.file_id,book_version=7}
local inventory={};for i=1,34 do inventory[i]={chapter_uid=tostring(i),chapter_idx=i,
    book_version=7,text_digest=string.rep('e',64),source_sha256=string.rep('a',64)} end
inventory[33].text_digest=digest
local opened=0;local cache={list=function() return inventory end,open=function(_,_,_,item)
    opened=opened+1;return {path='/chapter-'..item.chapter_uid,file_id=actual.file_id,book_version=7,source_sha256=item.source_sha256}
end}
local function scan(cursor,prior) return TimeSource.scan_page({},account,native.scope,wanted,cursor,prior,current,{cache=cache}) end
local page=scan(1);assert(page.kind=='more' and page.cursor==33 and opened==0)
local final=scan(page.cursor,page.prior);assert(final.kind=='found' and final.reference.chapter_uid=='33' and opened==1)
inventory[34].text_digest=digest
page=scan(1);final=scan(page.cursor,page.prior);assert(final.kind=='ambiguous','identical chapter fingerprint was guessed')
inventory[34].chapter_uid=inventory[33].chapter_uid
page=scan(1);final=scan(page.cursor,page.prior);assert(final.kind=='ambiguous','conflicting saved chapter indices were accepted')
inventory[34].chapter_uid='34'
inventory[34].text_digest=string.rep('e',64);page=scan(1)
inventory[1].chapter_uid='999';final=scan(page.cursor,page.prior)
assert(final.kind=='unavailable','changed inventory was accepted across pages')
inventory[33].chapter_idx=nil;page=scan(1);final=scan(page.cursor,page.prior)
assert(final.kind=='found','index-free chapter was not made available for online verification')
inventory[33].chapter_idx=33
cache.open=function() return nil end;page=scan(1);final=scan(page.cursor,page.prior)
assert(final.kind=='unavailable','corrupt matching chapter was skipped')
assert(TimeSource.scan_page({},string.rep('e',20),native.scope,wanted,1,nil,current,{cache=cache}).kind=='unavailable')
print('PASS: native reading-time source proof is account, file and version bound')
