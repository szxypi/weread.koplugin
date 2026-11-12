-- Actual SQLite failure/size/ownership tests, synthetic metadata only.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'))
assert(require('libs/libkoreader-lfs').mkdir(root))
local json=require('json');local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000'
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default)
    return key=='account' and {user_vid=account} or default
end}
local Cache=require('weread.lib.discovery_cache');local store=Cache:new(library,codec)
local checks=0
local function expect(value) checks=checks+1;assert(value) end
local function state(kind,cursor)
    return {kind=kind or 'search',keyword='Synthetic',cursor=cursor or 0,next_cursor=(cursor or 0)+20,has_more=true,
        books={{bookId='900001',title='Synthetic',author='',category='',cover='',searchIdx=20}},loaded_at=100,
        source_kind='native',source_revision='private-revision',session_id='private-session',cookies='private-cookie'}
end
local first=state();first._cache_generation=assert(store:write(first));expect(#first._cache_generation==32)
local next_page=state('search',20);next_page._cache_generation=assert(store:write(next_page,first,true))
expect(store:read(first,20).history[1]==0 and store:read(first,0).has_more)
expect(store:read().cursor==20 and store:read().cached)
local rawdb=library:open();local _,name,file=rawdb:rowexec('PRAGMA database_list');expect(name=='main' and file==library:databasePath())
local raw=rawdb:rowexec('SELECT payload FROM discovery_cache');rawdb:close()
expect(not raw:find('private',1,true) and not raw:find('session',1,true) and not raw:find('revision',1,true))
account='900099';expect(store:read()==nil);account='900000';expect(store:read().cursor==20)
local replacement=state();replacement._cache_generation=assert(store:write(replacement));expect(not store:read(first,0).has_more)
expect(not store:write(next_page,first,true) and store:read().cursor==0)
local previous=state();previous._cache_generation=replacement._cache_generation
for cursor=20,220,20 do local item=state('search',cursor);item._cache_generation=assert(store:write(item,previous,true));previous=item end
expect(store:read().cursor==220)
expect(not store:write(state('search',240),previous,true) and store:read().cursor==220)
-- Simulate an uncertain/failed COMMIT before SQLite accepts it; rollback must
-- preserve the old complete snapshot, never a new half-series.
local open=library.open
function library:open()
    local db=assert(open(self));local proxy={}
    function proxy.exec(_proxy,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return db:exec(sql) end
    function proxy.prepare(_proxy,sql) return db:prepare(sql) end
    function proxy.close(_proxy) return db:close() end
    return proxy
end
expect(not store:write(state()));library.open=open;expect(store:read().cursor==220)
local closed=false
function library:open()
    local db=assert(open(self));local proxy={}
    function proxy.exec(_proxy,sql) return db:exec(sql) end
    function proxy.prepare(_proxy,sql)
        local stmt=db:prepare(sql)
        if sql:find('SELECT cache_key,length',1,true) then
            return {step=function() error('synthetic SQLite cursor failure') end,close=function() closed=true;stmt:close() end}
        end
        return stmt
    end
    function proxy.close(_proxy) return db:close() end
    return proxy
end
expect(not store:write(state()) and closed);library.open=open;expect(store:read().cursor==220)
local oversized=state();for i=1,100 do
 oversized.books[i]={bookId=tostring(900000+i),title=string.rep('x',4096),author=string.rep('a',4096),category=string.rep('c',4096),cover=string.rep('u',8192)}
end
oversized._cache_generation=assert(store:write(oversized))
local second=state('search',20);second.books=oversized.books
expect(not store:write(second,oversized,true) and store:read().cursor==0)

for i=1,13 do local item=state();item.keyword='Query '..i;assert(store:write(item)) end
expect(not store:read{kind='search',keyword='Query 1'})
expect(store:read{kind='search',keyword='Query 13'}~=nil)
rawdb=library:open();expect(tonumber(rawdb:rowexec('SELECT COUNT(*) FROM discovery_cache'))==12)
rawdb:exec("UPDATE discovery_cache SET payload='{}' WHERE serial=(SELECT MAX(serial) FROM discovery_cache)");rawdb:close()
expect(store:read()==nil)
for i=1,10 do oversized.keyword='Budget '..i;assert(store:write(oversized)) end
rawdb=library:open();expect(tonumber(rawdb:rowexec('SELECT SUM(length(CAST(payload AS BLOB))) FROM discovery_cache'))<=Cache.MAX_TOTAL);rawdb:close()
expect(store:read{kind='search',keyword='Budget 1'}==nil and store:read{kind='search',keyword='Budget 10'}~=nil)
print('PASS: discovery SQLite cache; '..checks..' checks')
