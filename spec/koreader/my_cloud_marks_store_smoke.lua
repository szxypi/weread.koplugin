-- Real SQLite rollback, quotas, malformed records and account isolation.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local json=require('json');local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000'
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local Cache=require('weread.lib.my_cloud_marks_store');local cache=Cache:new(library,codec)
local checks=0
local function expect(value) checks=checks+1;assert(value) end
local function snapshot(id)
    return {schema=1,book_id=id or '900001',fetched_at=1000,updated={{bookmarkId='synthetic-mark',type=1,markText='合成引用',private='strip'}},
        chapters=json.decode('[]'),accessToken='strip'}
end
expect(cache:write(snapshot()));expect(cache:read('900001').updated[1].markText=='合成引用')
local db=assert(library:open());local raw=db:rowexec('SELECT payload FROM my_cloud_marks');db:close();expect(not raw:find('strip',1,true))
account='900099';expect(cache:read('900001')==nil);account='900000'
local open=library.open
function library:open()
    local handle=assert(open(self))
    return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return handle:exec(sql) end,
        prepare=function(_self,sql) return handle:prepare(sql) end,close=function() return handle:close() end}
end
local changed=snapshot();changed.updated[1].markText='unsaved'
expect(not cache:write(changed));library.open=open;expect(cache:read('900001').updated[1].markText=='合成引用')
local oversized=snapshot();oversized.updated={}
for i=1,33 do oversized.updated[i]={bookmarkId='synthetic-'..i,markText=string.rep('x',131072)} end
expect(not cache:write(oversized) and cache:read('900001').updated[1].markText=='合成引用')
for i=1,65 do expect(cache:write(snapshot(tostring(910000+i)))) end
expect(cache:read('910001')==nil and cache:read('910065')~=nil)
db=library:open();expect(tonumber(db:rowexec('SELECT COUNT(*) FROM my_cloud_marks'))==64)
db:exec("UPDATE my_cloud_marks SET payload='{}' WHERE book_id='910065'");db:close();expect(cache:read('910065')==nil)
-- Use actual near-limit snapshots to check the aggregate payload bound.
oversized=snapshot();oversized.updated={}
for i=1,30 do oversized.updated[i]={bookmarkId='synthetic-'..i,markText=string.rep('x',131072)} end
for i=1,10 do oversized.book_id=tostring(920000+i);expect(cache:write(oversized)) end
db=library:open();expect(tonumber(db:rowexec('SELECT SUM(length(CAST(payload AS BLOB))) FROM my_cloud_marks'))<=Cache.MAX_TOTAL);db:close()
expect(cache:read('920001')==nil and cache:read('920010')~=nil)
print('PASS: own cloud marks SQLite ('..checks..' checks)')
