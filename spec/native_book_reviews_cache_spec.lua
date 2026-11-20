package.path='./?.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=helper.connect} end
local json=require('json')
local codec={json_encode=function(_self,v) return json.encode(v) end,
    json_decode=function(_self,v) if v=='[]' then return {} end;return json.decode(v) end}
local user=os.tmpname();os.remove(user)
local account={user_vid=user};local settings={data_dir='/tmp',get=function() return account end}
local library=require('weread.lib.library_db'):new(settings)
local Cache=require('weread.lib.native_book_reviews_cache')
local cache=Cache:new(library,codec,library:accountKey());local path=library:databasePath()
local function page(count,limit)
    local items={}
    for i=1,count do items[i]={review_id='r'..i,author='Reader',content='text '..i,
        rating=4,create_time=1001-i,is_finish=false,idx=0} end
    return {items=items,limit=limit,has_more=count==limit,limited=false}
end
local first,longer=page(20,20),page(40,40)
local malformed=page(3,20);malformed.items[2]=nil;malformed.has_more=false
assert(not cache:write('42',malformed,1099),'sparse review list was accepted')
assert(cache:write('42',longer,1100) and cache:write('42',first,1200))
local saved=assert(cache:read('42'));assert(#saved.items==40 and saved.saved_at==1100)
first.items[1].content='updated';assert(cache:write('42',first,1300))
saved=assert(cache:read('42'));assert(#saved.items==20 and saved.items[1].content=='updated')
first.items[1].rating=0/0;assert(not cache:write('42',first,1400));first.items[1].rating=4
assert(cache:read('42').saved_at==1300)
local db=assert(library:open())
db:exec([[CREATE TRIGGER reject_review BEFORE INSERT ON native_book_reviews
    BEGIN SELECT RAISE(ABORT,'fixture'); END]])
db:close();assert(not cache:write('42',first,1500) and cache:read('42').saved_at==1300)
db=assert(library:open());db:exec('DROP TRIGGER reject_review');db:close()
account={user_vid=user..'-other'};local other_path=library:databasePath()
assert(not cache:read('42') and not cache:write('42',first,1500))
account={user_vid=user};assert(cache:read('42').saved_at==1300)
for i=1,33 do assert(cache:write(tostring(100+i),first,1500+i)) end
assert(not cache:read('42') and cache:read('133'))
db=assert(library:open());db:exec([[UPDATE native_book_reviews SET payload='{}' WHERE book_id='133']]);db:close()
assert(not cache:read('133'))
for _,file in ipairs({path,other_path}) do os.remove(file);os.remove(file..'-wal');os.remove(file..'-shm') end
helper.cleanup()
print('PASS: review cache prefix, rollback, bounds and account isolation')
