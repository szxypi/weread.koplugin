-- Exercise the real SQLite database, including account and transaction guards.
package.path='./?.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local Crypto=require('weread.lib.crypto')
local Store=require('weread.lib.native_direct_pending')
local scope={vid='123',epoch=1};local active=scope
local owner=require('weread.lib.native_position_contract').account_key(scope.vid)
local path=os.tmpname()
local library={accountKey=function() return owner end,open=function() return helper.connect(path) end,
    openRead=function() return helper.connect(path) end}
local settings={auth_scope_matches=function(_,value) return value==active end}
local entry={owner=Crypto.sha256_hex('native-direct-account\0'..scope.vid),book_id='42',chapter_uid='12',
    book_version=7,chapter_idx=1,title='Fixture',missing_images=0,text_digest=string.rep('b',64),
    source_sha256=string.rep('c',64),key=string.rep('d',64),copy=0,file_id=string.rep('a',64)}
local live=function() return true end
assert(not Store.read(library,settings,scope,entry,live))
assert(Store.save(library,settings,scope,entry,'/body/p.2',live))
local first=assert(Store.read(library,settings,scope,entry,live));assert(first.xpointer=='/body/p.2')
local cache=require('weread.lib.native_direct_cache');local original_open=cache.open
cache.open=function() return {file_id=entry.file_id} end
local listed={entry};assert(Store.mark(library,settings,scope,'42',listed,live) and entry.pending_offline==true,
    'verified saved chapter did not show its offline reminder')
entry.pending_offline=nil;cache.open=function() return {file_id=string.rep('e',64)} end
assert(Store.mark(library,settings,scope,'42',listed,live) and not entry.pending_offline,
    'changed saved file was given a reminder')
cache.open=original_open
assert(Store.save(library,settings,scope,entry,'/body/p.5',live))
assert(not Store.remove(library,settings,scope,entry,first,live),'old reminder deleted a newer one')
assert(assert(Store.read(library,settings,scope,entry,live)).xpointer=='/body/p.5')
local calls=0
assert(not Store.save(library,settings,scope,entry,'/body/p.6',function() calls=calls+1;return calls<3 end),
    'changed session committed a reminder')
assert(assert(Store.read(library,settings,scope,entry,live)).xpointer=='/body/p.5')
active={vid='456',epoch=2}
assert(not Store.read(library,settings,scope,entry,live) and not Store.save(library,settings,scope,entry,'x',live),
    'changed account accessed a reminder')
active=scope
local db=helper.connect(path);db:exec('BEGIN IMMEDIATE')
assert(not Store.save(library,settings,scope,entry,'x',live),'concurrent writer was ignored')
db:exec('ROLLBACK');db:close()
local new=assert(Store.read(library,settings,scope,entry,live));assert(Store.remove(library,settings,scope,entry,new,live))
assert(not Store.read(library,settings,scope,entry,live),'confirmed reminder not removed')
assert(not Store.save(library,settings,scope,entry,'bad\nanchor',live),'invalid pointer saved')
assert(Store.save(library,settings,scope,entry,'/valid',live))
db=helper.connect(path)
local insert=db:prepare('INSERT INTO native_direct_offline_pending VALUES(?,?,?,?,?,?,?,?)')
for i=1,Store.MAX_RECORDS-1 do
    insert:bind(string.format('%064x',i),'42','12',7,entry.source_sha256,entry.key,0,'/valid'):step();insert:reset()
end
insert:close();db:close()
local another={};for key,value in pairs(entry) do another[key]=value end;another.file_id=string.rep('e',64)
assert(not Store.save(library,settings,scope,another,'/new',live),'full quota silently evicted an offline reminder')
assert(Store.save(library,settings,scope,entry,'/updated',live),'full quota prevented updating the same reminder')
db=helper.connect(path);db:exec("UPDATE native_direct_offline_pending SET chapter_uid='99'");db:close()
assert(not Store.read(library,settings,scope,entry,live) and not Store.save(library,settings,scope,entry,'/other',live),
    'different identity was accepted or overwritten')
os.remove(path);os.remove(path..'-wal');os.remove(path..'-shm')
print('PASS: native offline reminders preserve account, identity, transaction and newer-position guards')
