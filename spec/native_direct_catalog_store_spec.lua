-- Actual SQLite with a deterministic fixture codec; no network or personal data.
package.path='./?.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local json=require('json')
local Crypto=require('weread.lib.crypto')
local Store=require('weread.lib.native_direct_catalog_store')
local scope={vid='123',epoch=1}
local current_scope=scope
local owner=require('weread.lib.native_position_contract').account_key(scope.vid)
local db_path=os.tmpname()
local library={accountKey=function() return owner end,
    open=function() return helper.connect(db_path) end,openRead=function() return helper.connect(db_path) end}
local settings={auth_scope_matches=function(_,value) return value==current_scope end}
local codec={json_encode=function(_,value) return json.encode(value) end,
    json_decode=function(_,value) return json.decode(value) end}
local live=function() return true end
local digest=Crypto.sha256_hex('catalog-0')
local catalog={book_id='42',version=7,reading_digest=digest,chapters={
    {chapterUid='11',wordCount=100,wordCountKnown=true},
    {chapterUid='12',wordCount=200,wordCountKnown=true},
    {chapterUid='13',wordCount=700,wordCountKnown=true},
}}
local entry={owner=Crypto.sha256_hex('native-direct-account\0'..scope.vid),book_id='42',chapter_uid='12',
    book_version=7,chapter_idx=1,title='Fixture',missing_images=0,text_digest=string.rep('b',64),
    source_sha256=string.rep('c',64),key=string.rep('d',64),copy=0,catalog_sha256=digest,
    catalog_order=2,catalog_count=3,catalog_prev='11',catalog_next='13'}
assert(not Store.read(library,settings,codec,scope,entry,live),'missing table returned a catalog')
assert(not Store.read_weights(library,settings,codec,scope,entry,live),'missing table returned weights')
assert(Store.save(library,settings,codec,scope,catalog,live),'catalog save failed')
local first=assert(Store.read(library,settings,codec,scope,entry,live))
assert(first.chapters[2].words==200 and math.abs(Store.estimate(first,entry,50)-20)<1e-9)
local weights=assert(Store.read_weights(library,settings,codec,scope,entry,live))
assert(weights.before==100 and weights.chapter==200 and weights.total==1000 and weights.chapters==nil)
assert(Store.estimate_from_weights(weights,50)==Store.estimate(first,entry,50))
assert(first.schema==1 and not Store.saved_orders(first,{entry}),'an older snapshot implied chapter levels')
local calls=0;catalog.chapters[2].wordCount=201
assert(not Store.save(library,settings,codec,scope,catalog,function() calls=calls+1;return calls<3 end),
    'changed session committed a catalog')
assert(assert(Store.read(library,settings,codec,scope,entry,live)).chapters[2].words==200,
    'failed transaction changed the catalog')
catalog.chapters[2].wordCount=200
catalog.chapters[1].level,catalog.chapters[1].title=0,'First section'
catalog.chapters[2].level,catalog.chapters[2].wordCountKnown=3,false
catalog.chapters[3].level=0
assert(Store.save(library,settings,codec,scope,catalog,live))
local outline=assert(Store.read(library,settings,codec,scope,entry,live))
assert(outline.schema==2 and outline.chapters[1].title=='First section' and outline.chapters[2].level==3
    and not outline.chapters[2].words and not Store.estimate(outline,entry,50),
    'saved outline required every word count or supplied an unsupported estimate')
assert(not Store.read_weights(library,settings,codec,scope,entry,live),'unknown word count returned weights')
local stale={};for key,value in pairs(entry) do stale[key]=value end
stale.catalog_prev='99'
assert(not Store.read_weights(library,settings,codec,scope,stale,live),'unverified catalog order returned weights')
local orders=assert(Store.saved_orders(outline,{stale,entry}))
assert(orders[1]==nil and orders[2]==2,'saved order accepted an inconsistent chapter reference')
outline.chapters[1].title='invalid\nline'
assert(not Store.saved_orders(outline,{entry}),'invalid section title was accepted')
catalog.chapters[2].wordCountKnown=true
assert(Store.save(library,settings,codec,scope,catalog,live))
assert(math.abs(Store.estimate(assert(Store.read(library,settings,codec,scope,entry,live)),entry,50)-20)<1e-9)
current_scope={vid='456',epoch=2}
assert(not Store.read(library,settings,codec,scope,entry,live) and not Store.save(library,settings,codec,scope,catalog,live),
    'changed account could access old catalog')
assert(not Store.read_weights(library,settings,codec,scope,entry,live),'old account could read catalog weights')
current_scope=scope
local db=helper.connect(db_path);db:exec('BEGIN IMMEDIATE')
assert(not Store.save(library,settings,codec,scope,catalog,live),'concurrent writer was ignored')
db:exec('ROLLBACK');db:close()
assert(Store.read(library,settings,codec,scope,entry,live),'concurrent writer damaged existing catalog')
for index=1,5 do
    catalog.reading_digest=Crypto.sha256_hex('catalog-'..index)
    assert(Store.save(library,settings,codec,scope,catalog,live))
end
assert(not Store.read(library,settings,codec,scope,entry,live),'oldest catalog was not evicted')
entry.catalog_sha256=catalog.reading_digest
assert(Store.read(library,settings,codec,scope,entry,live),'newest catalog was evicted')
db=helper.connect(db_path)
local query=db:prepare('SELECT COUNT(*) FROM native_direct_catalog_estimate WHERE book_id=?')
assert(tonumber(query:bind('42'):step()[1])==Store.MAX_PER_BOOK);query:close()
db:exec("UPDATE native_direct_catalog_estimate SET payload='corrupt'");db:close()
assert(not Store.read(library,settings,codec,scope,entry,live),'damaged catalog was accepted')
assert(not Store.read_weights(library,settings,codec,scope,entry,live),'damaged catalog returned weights')
os.remove(db_path);os.remove(db_path..'-wal');os.remove(db_path..'-shm')
print('PASS: native catalog cache protects account, transactions, quota and integrity')
