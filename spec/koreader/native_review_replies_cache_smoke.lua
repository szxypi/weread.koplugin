-- Real KOReader SQLite: account and thread isolation, retention, quota and rollback.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local json=require('json');local codec={json_encode=function(_self,v) return json.encode(v) end,
    json_decode=function(_self,v) return json.decode(v) end}
local account='900000'
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default)
    return key=='account' and {user_vid=account} or default
end}
local Store=require('weread.lib.native_review_replies_cache')
local store=Store:new(library,codec,library:accountKey())
local function page(n)
    local items={}
    for i=1,n do items[i]={review_id='r'..i,author='Reader',content='Synthetic reply',rating=0,
        create_time=1000+i,is_finish=false,idx=0} end
    return {items=items,limit=n,has_more=true,limited=false}
end
local short,long=page(20),page(40)
assert(store:write('900001','thread',4,long,1200) and store:write('900001','thread',4,short,1201))
local saved=assert(store:read('900001','thread',4));assert(#saved.items==40 and saved.saved_at==1200)
assert(not store:read('900001','thread',1) and not store:read('900002','thread',4))
assert(store:write('900001','thread',1,short,1201) and store:read('900001','thread',1))
short.items[1].content='Changed';assert(store:write('900001','thread',4,short,1202))
assert(#store:read('900001','thread',4).items==20)
short.items[1].content=string.rep('x',131073)
assert(not store:write('900001','thread',4,short,1203) and store:read('900001','thread',4).saved_at==1202)
short.items[1].content='Changed'
local db=assert(library:open())
local trigger=db:prepare([[CREATE TRIGGER reject_reply BEFORE INSERT ON native_review_replies BEGIN SELECT RAISE(ABORT,'fixture'); END]])
trigger:step();trigger:close();db:close()
assert(not store:write('900001','thread',4,short,1203) and store:read('900001','thread',4).saved_at==1202)
db=assert(library:open());db:exec('DROP TRIGGER reject_reply');db:close()
account='900099';assert(not store:read('900001','thread',4) and not store:write('900001','thread',4,short,1204))
account='900000';assert(store:read('900001','thread',4))
for i=1,65 do assert(store:write('900001','thread'..i,4,short,1204+i)) end
assert(not store:read('900001','thread',4) and store:read('900001','thread65',4))
db=assert(library:open());assert(db:rowexec('SELECT COUNT(*) FROM native_review_replies')==Store.MAX_THREADS)
db:exec([[UPDATE native_review_replies SET payload='{}' WHERE review_id='thread65']]);db:close()
assert(not store:read('900001','thread65',4))
print('PASS: reply cache SQLite scope, retention, quota, rollback and invalid snapshots')
