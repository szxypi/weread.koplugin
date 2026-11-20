package.path='./?.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=helper.connect} end
local json=require('json')
local codec={json_encode=function(_self,v) return json.encode(v) end,
    json_decode=function(_self,v) if v=='[]' then return {} end;return json.decode(v) end}
local user=os.tmpname();os.remove(user)
local account={user_vid=user};local settings={data_dir='/tmp',get=function() return account end}
local library=require('weread.lib.library_db'):new(settings)
local Cache=require('weread.lib.native_review_replies_cache')
local cache=Cache:new(library,codec,library:accountKey());local path=library:databasePath()
local function page(count,limit)
    local items={}
    for i=1,count do items[i]={review_id='r'..i,author='Reader',content='reply '..i,
        rating=0,create_time=1000+i,is_finish=false,idx=0} end
    return {items=items,limit=limit,has_more=count==limit,limited=false}
end
local first,longer=page(20,20),page(40,40)
local malformed=page(3,20);malformed.items[2]=nil;malformed.has_more=false
assert(not cache:write('42','thread',4,malformed,1099))
assert(cache:write('42','thread',4,longer,1100) and cache:write('42','thread',4,first,1200))
local saved=assert(cache:read('42','thread',4));assert(#saved.items==40 and saved.saved_at==1100)
assert(not cache:read('42','thread',1) and not cache:read('43','thread',4) and not cache:read('42','other',4))
first.items[1].content='updated';assert(cache:write('42','thread',4,first,1300))
saved=assert(cache:read('42','thread',4));assert(#saved.items==20 and saved.items[1].content=='updated')
assert(cache:write('42','thread',1,first,1301) and cache:read('42','thread',1).saved_at==1301)
first.items[1].rating=1;assert(not cache:write('42','thread',4,first,1400));first.items[1].rating=0
local db=assert(library:open())
db:exec([[CREATE TRIGGER reject_reply BEFORE INSERT ON native_review_replies
    BEGIN SELECT RAISE(ABORT,'fixture'); END]])
db:close();assert(not cache:write('42','thread',4,first,1500) and cache:read('42','thread',4).saved_at==1300)
db=assert(library:open());db:exec('DROP TRIGGER reject_reply');db:close()
account={user_vid=user..'-other'};local other_path=library:databasePath()
assert(not cache:read('42','thread',4) and not cache:write('42','thread',4,first,1500))
account={user_vid=user};assert(cache:read('42','thread',4).saved_at==1300)
for i=1,65 do assert(cache:write('42','thread'..i,4,first,1500+i)) end
assert(not cache:read('42','thread',4) and cache:read('42','thread65',4))
db=assert(library:open());db:exec([[UPDATE native_review_replies SET payload='{}' WHERE review_id='thread65']]);db:close()
assert(not cache:read('42','thread65',4))
for _,file in ipairs({path,other_path}) do os.remove(file);os.remove(file..'-wal');os.remove(file..'-shm') end
helper.cleanup()
print('PASS: reply cache scope, prefix, rollback, bounds and isolation')
