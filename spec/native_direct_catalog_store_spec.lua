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
assert(Store.save(library,settings,codec,scope,catalog,live),'catalog save failed')
local first=assert(Store.read(library,settings,codec,scope,entry,live))
assert(first.chapters[2].words==200 and math.abs(Store.estimate(first,entry,50)-20)<1e-9)
local calls=0;catalog.chapters[2].wordCount=201
assert(not Store.save(library,settings,codec,scope,catalog,function() calls=calls+1;return calls<3 end),
    'changed session committed a catalog')
assert(assert(Store.read(library,settings,codec,scope,entry,live)).chapters[2].words==200,
    'failed transaction changed the catalog')
catalog.chapters[2].wordCount=200
current_scope={vid='456',epoch=2}
assert(not Store.read(library,settings,codec,scope,entry,live) and not Store.save(library,settings,codec,scope,catalog,live),
    'changed account could access old catalog')
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
os.remove(db_path);os.remove(db_path..'-wal');os.remove(db_path..'-shm')
print('PASS: native catalog cache protects account, transactions, quota and integrity')
