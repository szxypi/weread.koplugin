-- Real SQLite: bounds, account isolation, rollback and offline cache integrity.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local json=require('json');local codec={json_encode=function(_self,v) return json.encode(v) end,
    json_decode=function(_self,v) return json.decode(v) end}
local account='900000'
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default)
    return key=='account' and {user_vid=account} or default
end}
local Store=require('weread.lib.native_book_reviews_cache')
local owner=library:accountKey();local store=Store:new(library,codec,owner)
assert(not store:read('900001'))
local page={items={},limit=20,has_more=true,limited=false}
for i=1,20 do page.items[i]={review_id='r'..i,author='Reader',content='Synthetic review',rating=4.5,
    create_time=1001-i,is_finish=false,idx=0} end
assert(store:write('900001',page,1200))
local saved=assert(store:read('900001'))
assert(saved.items[1].content=='Synthetic review' and saved.ids[1]=='r1' and saved.has_more and saved.saved_at==1200)
local empty={items=json.decode('[]'),limit=20,has_more=false,limited=false}
assert(store:write('900002',empty,1200) and #store:read('900002').items==0)
local longer={items={},limit=40,has_more=true,limited=false}
for i=1,40 do longer.items[i]=i<=20 and page.items[i] or {review_id='r'..i,author='Reader',content='Second',rating=5,
    create_time=1001-i,is_finish=true,idx=0} end
assert(store:write('900001',longer,1201) and store:write('900001',page,1202))
saved=assert(store:read('900001'));assert(#saved.items==40 and saved.saved_at==1201,'short prefix discarded saved reviews')
page.items[1].content='Changed review'
assert(store:write('900001',page,1203) and #store:read('900001').items==20,'changed prefix reused stale reviews')
page.items[1].content='Synthetic review';assert(store:write('900001',page,1200))
local original=page.items[1].content;page.items[1].content=string.rep('x',131073)
assert(not store:write('900001',page,1201) and store:read('900001').items[1].content==original)
page.items[1].content=original
local db=assert(library:open())
local trigger=db:prepare([[CREATE TRIGGER reject_review BEFORE INSERT ON native_book_reviews BEGIN SELECT RAISE(ABORT,'fixture'); END]])
trigger:step();trigger:close()
db:close();assert(not store:write('900001',page,1202) and store:read('900001').saved_at==1200)
db=assert(library:open());db:exec('DROP TRIGGER reject_review');db:close()
account='900099';assert(not store:read('900001') and not store:write('900001',page,1203))
local other=Store:new(library,codec,library:accountKey());assert(not other:read('900001'))
account='900000';assert(store:read('900001').saved_at==1200)
for i=1,33 do assert(store:write(tostring(910000+i),page,1204+i)) end
assert(not store:read('900001') and store:read('910033'))
db=assert(library:open());assert(db:rowexec('SELECT COUNT(*) FROM native_book_reviews')==Store.MAX_BOOKS)
db:exec([[UPDATE native_book_reviews SET payload='{}' WHERE book_id='910033']]);db:close()
assert(not store:read('910033'))
print('PASS: saved review SQLite bounds, rollback, account isolation and invalid snapshots')
