package.path='./?.lua;./?/init.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local Json=require('json')
local codec={json_encode=function(_self,v) return Json.encode(v) end,json_decode=function(_self,v) return Json.decode(v) end}
local Store=require('weread.lib.translation_resume')
local path_a,path_b=os.tmpname(),os.tmpname()
local account='account-a';local valid=true
local library={settings={auth_scope_matches=function(_self,scope) return valid and scope.account==account end},
    accountKey=function() return account end,open=function() return helper.connect(account=='account-a' and path_a or path_b) end}
local store=Store:new(library,codec,{account='account-a'})
local chapters={{chapterUid=1,title='One'},{chapterUid=2,title='Two'}}
local source=string.rep('a',64)
local function make(resume,items,version,id) return store:begin('42',id or source,items or chapters,version or 7,resume) end
local token=assert(make(false))
assert(store:token('42').generation==token.generation and not store:token('missing').generation)
assert(store:tokens()['42'].generation==token.generation,'cleanup preview lost checkpoint generation')
assert(not store:summary('42',source),'empty checkpoint shown as resumable')
assert(store:put(token,'1','<p>first</p>'))
assert(store:get(token,'1')=='<p>first</p>')
assert(store:summary('42',source).count==1)
local restored=assert(make(true))
assert(restored.generation==token.generation and store:get(restored,'1')=='<p>first</p>','resume lost cached source')
assert(not store:summary('42',string.rep('b',64)),'other source inherited checkpoint')
local changed=assert(make(true,{{chapterUid=1,title='Changed'},{chapterUid=2,title='Two'}}))
assert(changed.generation~=token.generation and not store:get(changed,'1'),'changed catalog reused old content')
assert(not store:put(token,'2','stale'),'old process wrote to new generation')
assert(not store:clear(token) and store:token('42').generation==changed.generation,'stale cleanup removed replacement')
assert(store:put(changed,'1','replacement'))
local newer=assert(make(true,nil,8))
assert(newer.generation~=changed.generation and not store:get(newer,'1'),'changed version reused old content')
assert(store:put(newer,'1','integrity'))
local db=assert(library:open());local stmt=db:prepare("UPDATE translation_pending_chapters SET raw='tampered' WHERE book_id='42'")
stmt:step();stmt:close();db:close()
assert(not store:get(newer,'1'),'corrupt source was accepted')
account='account-b';assert(not store:get(newer,'1') and not store:put(newer,'2','wrong owner'))
local other=Store:new(library,codec,{account='account-b'})
assert(not other:summary('42',source),'other account saw checkpoint')
account='account-a';valid=false;assert(not store:get(newer,'1') and not store:clear(newer),'expired login accessed checkpoint')
valid=true;assert(store:clear(newer) and not store:summary('42',source),'accepted checkpoint was not cleared')
local unversioned=assert(store:begin('42',source,chapters,nil,false))
assert(store:put(unversioned,'1','unversioned'))
assert(store:begin('42',source,chapters,nil,true).generation==unversioned.generation,
    'explicitly accepted unversioned chapters did not resume')
assert(store:clear(unversioned))
local capacity=Store.MAX_TOTAL;Store.MAX_TOTAL=10
local first=assert(store:begin('1',source,chapters,7,false))
local second=assert(store:begin('2',source,chapters,7,false))
assert(store:put(first,'1','12345678') and not store:put(second,'1','123'),'storage limit was not enforced')
assert(store:put(first,'1','12') and store:put(second,'1','123'),'replacement did not release capacity')
Store.MAX_TOTAL=capacity
local third=assert(store:begin('3',source,chapters,7,false))
local fourth=assert(store:begin('4',source,chapters,7,false))
assert(not store:begin('5',source,chapters,7,false),'checkpoint count was not bounded')
for _,entry in ipairs({first,second,third,fourth}) do assert(store:clear(entry)) end
for _,path in ipairs({path_a,path_b}) do os.remove(path);os.remove(path..'-wal');os.remove(path..'-shm') end
print('translation_resume_spec: SQLite resume, identity, scope, integrity and replacement passed')
