package.path='./?.lua;./?/init.lua;'..package.path
local Cache=require('weread.lib.discovery_cache')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function rejected(fn) local ok=pcall(fn);expect(not ok,'invalid cache accepted') end
local function book() return {bookId='900001',title='Title',author='Author',category='',cover='',searchIdx=20,private_extra='discard'} end
local function snapshot()
    return {schema=1,generation=string.rep('a',32),query={kind='similar',book_id='900100',book_title='Seed',session_id='do not persist'},
        source_kind='native',updated_at=100,pages={
            {cursor=0,next_cursor=20,has_more=true,loaded_at=100,books={book()}},
            {cursor=20,next_cursor=21,has_more=false,loaded_at=101,books={book()}}}}
end
local value=Cache.validate(snapshot())
expect(value.query.session_id==nil and value.pages[1].books[1].private_extra==nil,'private fields not stripped')
local state=Cache.state(value,0)
expect(state.cached and state.has_more and state.next_cursor==20 and #state.history==0,'first saved batch')
state.books[1].title='Changed on screen'
expect(value.pages[1].books[1].title=='Title' and not value.query.cached,'restored state changed the supplied snapshot')
local detailed=snapshot()
detailed.pages[1].books[1].reason='Recommended for you'
detailed.pages[1].books[1]._public_info={intro='Public introduction',publisher='Public publisher',newRating=860,newRatingCount=12,token='secret'}
local restored=Cache.state(Cache.validate(detailed),0).books[1]._public_info
expect(restored.intro=='Public introduction' and restored.publisher=='Public publisher'
    and restored.newRating==860 and restored.newRatingCount==12 and not restored.token,'public details not isolated or retained in cache')
expect(Cache.state(Cache.validate(detailed),0).books[1].reason=='Recommended for you','recommendation reason lost offline')
for _,invalid in ipairs({string.char(255),'line\nbreak',string.rep('x',513)}) do
    local bad=snapshot();bad.pages[1].books[1].reason=invalid
    rejected(function() Cache.validate(bad) end)
end
local broken=snapshot();broken.pages[2].books[1].author=false
rejected(function() Cache.state(broken,0) end)
expect(not state.session_id and not state.source_revision and not state._cache_generation,'remote binding restored from disk')
state=Cache.state(value,20)
expect(not state.has_more and state.history[1]==0 and state.books[1].title=='Title','saved continuation history')
expect(Cache.state(value).cursor==20,'last viewed batch')
value.pages[2]=nil;expect(not Cache.state(value,0).has_more and Cache.state(value,20)==nil,'uncached next batch offered')
for _,query in ipairs({{kind='recommend'},{kind='search',keyword='三体'},
    {kind='similar',book_id='900100',book_title='Renamed seed'},
    {kind='category',category_id='rising',category_title='Ranking',rank=true},
    {kind='category',category_id='1001',category_title='Category',rank=false}}) do
    expect(#Cache.key(query)==64,'query key')
end
expect(Cache.key(snapshot().query)==Cache.key{kind='similar',book_id='900100',book_title='New title'},'display title changed identity')
expect(Cache.key{kind='search',keyword='foo'}~=Cache.key{kind='search',keyword='foobar'},'query collision')
local same_word={kind='search',keyword='foo'}
expect(Cache.key(same_word)~=Cache.key(same_word,true),'public and ordinary searches shared a cache key')
expect(Cache.key{kind='category',category_id='a',category_title='A',rank=true}~=Cache.key{kind='category',category_id='a',category_title='A',rank=false},'rank collision')
for _,change in ipairs({'generation','books','duplicate','cursor','time','more','missing_first','limit','type'}) do
    local row=snapshot()
    if change=='generation' then row.generation='bad'
    elseif change=='books' then row.pages[1].books[1].title=string.rep('x',4097)
    elseif change=='duplicate' then row.pages[2].cursor=0
    elseif change=='cursor' then row.pages[1].cursor=true
    elseif change=='time' then row.pages[1].loaded_at=0/0
    elseif change=='more' then row.pages[1].next_cursor=0
    elseif change=='missing_first' then row.pages[1].cursor=1
    elseif change=='limit' then for i=1,13 do row.pages[i]={cursor=i-1,next_cursor=i,has_more=true,loaded_at=1,books={}} end
    else row.pages[1].books={unknown=book()} end
    rejected(function() Cache.validate(row) end)
end
rejected(function() Cache.query{kind='search',keyword='line\nbreak'} end)
rejected(function() Cache.query{kind='search',keyword=string.char(255)} end)
rejected(function() Cache.query{kind='unknown'} end)
print('discovery_cache_spec: '..checks..' checks')
