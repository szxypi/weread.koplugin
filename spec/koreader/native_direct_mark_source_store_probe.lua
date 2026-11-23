-- Real SQLite source-cache boundaries; all input is synthetic.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(os.getenv('KO_HOME'));assert(root:match('^/dev/shm/'))
local Crypto=require('weread.lib.crypto');local owner='12345678';local body='<html><body>Synthetic source text.</body></html>'
local settings={data_dir=root,get=function(_,key,default) if key=='account' then return {user_vid=owner} end;return default end}
local library=require('weread.lib.library_db'):new(settings)
local Store=require('weread.lib.native_direct_mark_source_store');Store.MAX_ENTRIES=2
local store=Store:new(library)
local function entry(char)
    return {book_id='42',chapter_uid='37',book_version=7,chapter_idx=1,file_id=string.rep('a',64),
        key=string.rep(char,64),source_sha256=Crypto.sha256_hex(body),copy=0,title='fixture',missing_images=0,
        text_digest=string.rep('c',64),owner=Crypto.sha256_hex('native-direct-account\0'..'12345678')}
end
local first,second,third=entry('1'),entry('2'),entry('3')
assert(store:read(first)==nil and store:write(first,body) and store:read(first)==body)
assert(not store:write(first,body..'changed') and store:read(first)==body)
owner='87654321';assert(store:read(first)==nil,'cached source crossed account');owner='12345678'
assert(store:write(second,body) and store:write(third,body))
assert(store:read(first)==nil and store:read(second)==body and store:read(third)==body,'source quota failed')
local db=assert(library:open());db:exec("UPDATE native_direct_mark_source SET body='corrupt'");db:close()
assert(store:read(second)==nil and store:read(third)==nil,'changed source accepted')
assert(store:write(second,body) and store:read(second)==body,'cache could not recover')
Store.MAX_ENTRIES=8;Store.MAX_TOTAL=#body
local fourth=entry('4');assert(store:write(fourth,body))
assert(store:read(second)==nil and store:read(fourth)==body,'byte quota did not evict older sources')
assert(not store:write(entry('5'),string.rep('x',Store.MAX_SOURCE+1)),'oversized source accepted')
print('WEREAD_DIRECT_SOURCE_STORE=PASS')
