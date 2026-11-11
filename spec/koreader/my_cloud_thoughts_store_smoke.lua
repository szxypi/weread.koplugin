require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local json=require('json');local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000'
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local Store=require('weread.lib.my_cloud_marks_store');local marks=Store:new(library,codec);local thoughts=Store:new(library,codec,'thoughts')
local checks=0;local function expect(value) checks=checks+1;assert(value) end
local mark={schema=1,book_id='900001',fetched_at=1000,updated={{bookmarkId='synthetic-mark',type=1,markText='Saved quote'}},chapters=json.decode('[]')}
local thought={schema=1,book_id='900001',fetched_at=1000,reviews={{reviewId='synthetic-thought',content='Saved thought',abstract='Quote',isPrivate=1,userVid='discard'}},token='discard'}
expect(marks:write(mark) and thoughts:write(thought))
expect(marks:read('900001').updated[1].markText=='Saved quote' and thoughts:read('900001').reviews[1].content=='Saved thought')
expect(not marks:write(thought) and not thoughts:write(mark))
local db=library:open();local raw=db:rowexec('SELECT payload FROM my_cloud_thoughts');db:close();expect(not raw:find('discard',1,true))
account='900099';expect(not thoughts:read('900001'));account='900000'
local open=library.open
function library:open()
    local handle=assert(open(self));return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic failure') end;return handle:exec(sql) end,
        prepare=function(_self,sql) return handle:prepare(sql) end,close=function() return handle:close() end}
end
local changed={schema=1,book_id='900001',fetched_at=1001,reviews={{reviewId='synthetic-thought',content='Unsaved'}}}
expect(not thoughts:write(changed));library.open=open
expect(thoughts:read('900001').reviews[1].content=='Saved thought' and marks:read('900001').updated[1].markText=='Saved quote')
for i=1,65 do changed.book_id=tostring(910000+i);expect(thoughts:write(changed)) end
expect(not thoughts:read('910001') and thoughts:read('910065')~=nil and marks:read('900001')~=nil)
expect(not pcall(Store.new,Store,library,codec,'untrusted_table'))
print('PASS: personal thought SQLite and highlight isolation ('..checks..' checks)')
