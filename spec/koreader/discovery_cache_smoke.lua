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
local function expect(value,message) checks=checks+1;assert(value,message) end
local function state(kind,cursor)
    return {kind=kind or 'search',keyword='Synthetic',cursor=cursor or 0,next_cursor=(cursor or 0)+20,has_more=true,
        books={{bookId='900001',title='Synthetic',author='',category='',cover='',searchIdx=20}},loaded_at=100,
        source_kind='native',source_revision='private-revision',session_id='private-session',cookies='private-cookie'}
end
local first=state();first._cache_generation=assert(store:write(first));expect(#first._cache_generation==32)
first.books[1]._public_info={intro='Public excerpt',publisher='Public publisher',newRating=860,newRatingCount=12,token='secret'}
first._cache_generation=assert(store:write(first))
local public_info=assert(store:read(first,0).books[1]._public_info)
expect(public_info.intro=='Public excerpt' and public_info.publisher=='Public publisher'
    and public_info.newRating==860 and public_info.newRatingCount==12 and not public_info.token)
local next_page=state('search',20)
next_page.books[1]._public_info={intro='Second public excerpt'}
local PublicInfo=require('weread.lib.public_book_info')
local project=PublicInfo.project
local projected=0
local function count_public_info(...)
    projected=projected+1
    return project(...)
end
PublicInfo.project=count_public_info
next_page._cache_generation=assert(store:write(next_page,first,true))
expect(projected==2,'a save did not validate both its previous and new batches')
projected=0
local cached_next=assert(store:read(first,20))
expect(projected==1 and cached_next.books[1]._public_info.intro=='Second public excerpt',
    'an explicit cache read projected public details for an unseen batch')
projected=0
local reference=assert(cached_next._cache_view)
local cached_reference=assert(store:read_reference(reference.key,reference.generation,0))
expect(projected==1 and cached_reference.books[1]._public_info.intro=='Public excerpt',
    'a cache reference read projected public details for an unseen batch')
projected=0
expect(store:read(first,400)==nil and projected==0,'an absent batch projected public details')
expect(store:read(first,20).history[1]==0 and store:read(first,0).has_more)
projected=0
local newest=assert(store:read())
expect(newest.cursor==20 and newest.cached and projected==1,
    'opening the latest batch projected public details for an unseen batch')
local rawdb=library:open();local _,name,file=rawdb:rowexec('PRAGMA database_list');expect(name=='main' and file==library:databasePath())
local raw=rawdb:rowexec('SELECT payload FROM discovery_cache');rawdb:close()
expect(not raw:find('private',1,true) and not raw:find('session',1,true) and not raw:find('revision',1,true))
local browse=assert(store:read(first,0))
expect(store:remember(browse,{anchor=2,focus='900001'}))
projected=0
local reopened=assert(store:read())
PublicInfo.project=project
expect(projected==1 and reopened.books[1]._public_info.intro=='Public excerpt',
    'restoring the last view projected public details for an unseen batch')
expect(reopened.cursor==0 and reopened._browse_saved and reopened._browse_position.anchor==2
    and reopened._browse_position.focus=='900001' and not reopened.source_revision and not reopened.session_id)
rawdb=library:open();expect(rawdb:rowexec('SELECT payload FROM discovery_cache')==raw);rawdb:close()
expect(not store:remember(browse,{anchor=0}) and not store:remember(browse,{anchor=2,focus='bad\ntext'}))
expect(store:remember(browse,{anchor=1}) and store:read()._browse_position.focus==nil)
rawdb=library:open();rawdb:exec("UPDATE discovery_position SET generation='stale'");rawdb:close()
expect(store:read().cursor==20 and not store:read()._browse_position)
expect(store:remember(browse,{anchor=1}))
account='900099';expect(store:read()==nil);account='900000';expect(store:read().cursor==0)
local replacement=state();replacement._cache_generation=assert(store:write(replacement));expect(not store:read(first,0).has_more)
expect(not store:remember(browse,{anchor=2}) and not store:read()._browse_position)
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
local refreshed_batch=state('search',20);refreshed_batch.books[1].title='Refreshed second batch'
expect(store:write(refreshed_batch,previous,true)==previous._cache_generation)
expect(store:read().cursor==20 and store:read(first,20).books[1].title=='Refreshed second batch'
    and store:read(first,220).cursor==220)
local wrong_source=state();wrong_source.source_kind='unknown'
expect(not store:write(wrong_source) and store:read().cursor==20)
rawdb=library:open()
local saved_payload=rawdb:rowexec('SELECT payload FROM discovery_cache')
local damaged=json.decode(saved_payload);damaged.pages[1].books[1].title=false
local function set_payload(payload)
    local statement=rawdb:prepare('UPDATE discovery_cache SET payload=?')
    statement:bind(payload):step();statement:close()
end
set_payload(json.encode(damaged))
expect(not store:write(refreshed_batch,previous,true) and not store:read(first,20))
set_payload(saved_payload);rawdb:close()
expect(store:read(first,20).books[1].title=='Refreshed second batch')
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
local searches=store:searches()
expect(#searches==11 and searches[1]=='Query 12' and searches[#searches]=='Query 2')
account='900099';expect(#store:searches()==0);account='900000'
expect(store:searches()[1]=='Query 12')
local entry=assert(store:search_entries()[1]);expect(entry.keyword=='Query 12' and #entry.generation==32)
local refreshed=state();refreshed.keyword=entry.keyword
local new_generation=assert(store:write(refreshed));expect(new_generation~=entry.generation)
expect(store:remove_search(entry.keyword,entry.generation)=='changed' and store:read{kind='search',keyword=entry.keyword})
account='900099';expect(store:remove_search(entry.keyword,new_generation)=='changed');account='900000'
expect(store:read{kind='search',keyword=entry.keyword} and store:read{kind='search',keyword='Query 11'})
function library:open()
    local db=assert(open(self));local proxy={}
    function proxy.exec(_proxy,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return db:exec(sql) end
    function proxy.prepare(_proxy,sql) return db:prepare(sql) end
    function proxy.close(_proxy) return db:close() end
    return proxy
end
expect(not store:remove_search(entry.keyword,new_generation));library.open=open
expect(store:read{kind='search',keyword=entry.keyword} and store:remove_search(entry.keyword,new_generation)=='deleted')
expect(not store:read{kind='search',keyword=entry.keyword} and store:read{kind='search',keyword='Query 11'})
expect(store:remove_search(entry.keyword,new_generation)=='changed' and not store:remove_search('Query 11','bad'))
for i=1,10 do oversized.keyword='Budget '..i;assert(store:write(oversized)) end
rawdb=library:open();expect(tonumber(rawdb:rowexec('SELECT SUM(length(CAST(payload AS BLOB))) FROM discovery_cache'))<=Cache.MAX_TOTAL);rawdb:close()
expect(store:read{kind='search',keyword='Budget 1'}==nil and store:read{kind='search',keyword='Budget 10'}~=nil)
local function search(kind,cursor)
    local item=state('search',cursor);item.keyword='Shared search';item.source_kind=kind
    item.books[1].bookId=kind..'-'..tostring(item.cursor)
    item.books[1]._public_info={intro='Search result detail'}
    return item
end
local public_first=search('public')
public_first._cache_generation=assert(store:write(public_first))
-- Simulate an installed profile with a public result under the old shared key.
rawdb=library:open()
local move=rawdb:prepare('UPDATE discovery_cache SET cache_key=? WHERE cache_key=?')
move:bind(Cache.key(public_first),Cache.key(public_first,true)):step();move:close();rawdb:close()
expect(store:read({kind='search',keyword='Shared search',public_only=true},0).books[1].bookId=='public-0')
local ordinary_first=search('native')
ordinary_first._cache_generation=assert(store:write(ordinary_first))
local standard_query={kind='search',keyword='Shared search'}
local native_query={kind='search',keyword='Shared search',source_kind='native'}
local public_query={kind='search',keyword='Shared search',source_kind='public'}
expect(store:read(standard_query,0).books[1].bookId=='native-0' and store:read(public_query,0).books[1].bookId=='public-0')
local public_second=search('public',20);public_second._cache_generation=assert(store:write(public_second,public_first,true))
expect(store:read(public_query,20).books[1].bookId=='public-20' and not store:read(native_query,20)
    and not store:read(standard_query,20))
local ordinary_second=search('native',20);ordinary_second._cache_generation=assert(store:write(ordinary_second,ordinary_first,true))
expect(store:read(native_query,20).books[1].bookId=='native-20' and store:read(public_query,20).history[1]==0)
local entries=assert(store:search_entries())
expect(entries[1].keyword=='Shared search' and entries[1].source_kind=='native'
    and entries[2].keyword==entries[1].keyword and entries[2].source_kind=='public')
expect(store:remove_search('Shared search',public_second._cache_generation,'native')=='changed')
expect(store:remember(assert(store:read(public_query,0)),{anchor=1,focus='public-0'}))
expect(store:read().source_kind=='public' and store:read().cursor==0)
projected=0
PublicInfo.project=count_public_info
expect(store:remove_search('Shared search',public_second._cache_generation,'public')=='deleted')
PublicInfo.project=project
expect(projected==0 and store:read(native_query,20) and not store:read(public_query,0),
    'removing a saved search built cards or altered another source')
expect(store:read().source_kind=='native' and store:read().cursor==20)

account='900099'
local native_search=search('native')
local public_search=search('public')
local old_public=search('public');old_public.keyword='Legacy public search'
local category=state('category');category.category_id='synthetic';category.category_title='Category';category.rank=false
local similar=state('similar');similar.book_id='900001';similar.book_title='Synthetic seed'
local damaged_search=state();damaged_search.keyword='Damaged search'
for _,item in ipairs({native_search,public_search,old_public,category,similar,state('recommend'),damaged_search}) do
    item.books[1]._public_info={intro='Synthetic public description'}
    assert(store:write(item))
end
rawdb=library:open()
move=rawdb:prepare('UPDATE discovery_cache SET cache_key=? WHERE cache_key=?')
move:bind(Cache.key(old_public),Cache.key(old_public,true)):step();move:close()
local damage=rawdb:prepare('UPDATE discovery_cache SET payload=? WHERE cache_key=?')
local broken=rawdb:prepare('SELECT payload FROM discovery_cache WHERE cache_key=?')
local invalid=codec:json_decode(broken:bind(Cache.key(damaged_search)):step()[1]);broken:close()
invalid.pages[1].books[1].title=false
damage:bind(codec:json_encode(invalid),Cache.key(damaged_search)):step();damage:close()
rawdb:close()
projected=0
PublicInfo.project=count_public_info
entries=assert(store:search_entries())
PublicInfo.project=project
expect(projected==0,'search history built cards to show query metadata')
expect(#entries==3 and entries[1].keyword==old_public.keyword and entries[1].source_kind=='public'
    and entries[2].keyword==public_search.keyword and entries[2].source_kind=='public'
    and entries[3].keyword==native_search.keyword and entries[3].source_kind=='native',
    'search history lost valid entries, changed their order, or showed a damaged batch')
expect(store:read(category,0) and store:read(similar,0) and store:read(state('recommend'),0),
    'skipping non-search batches altered their cached results')
print('PASS: discovery SQLite cache; '..checks..' checks')
