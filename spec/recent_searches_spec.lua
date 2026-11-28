package.path='./?.lua;./?/init.lua;'..package.path
local H=require('weread.lib.recent_searches')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local account='a';local values={};local db={}
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
function db:accountKey() return account end
function db:getProfileState(key) assert(key==H.KEY);return values[account] end
function db:compareProfileState(key,before,after)
    assert(key==H.KEY);if not equal(before,values[account]) then return false end
    values[account]=after;return true
end
local host={library_db=db}
expect(H.record(host,'  三体  ',false),'normal search not saved')
expect(H.record(host,'三体',true),'public search not saved')
expect(H.record(host,'Second',false),'second term not saved')
expect(H.record(host,'三体',false),'repeat search failed')
local list,err,owner=H.list(host);local original;local _
expect(not err and owner=='a' and #list.entries==3 and list.entries[1].keyword=='三体'
    and not list.entries[1].public and list.entries[2].keyword=='Second' and list.entries[3].public,'order or mode wrong')
for i=1,23 do expect(H.record(host,'word'..i,false),'bounded insertion failed') end
list,_,owner,original=H.list(host)
expect(#list.entries==20 and list.entries[1].keyword=='word23' and list.entries[20].keyword=='word4','history limit or order wrong')
expect(not H.record(host,' \t ',false) and not H.record(host,'bad\ntext',false)
    and not H.record(host,string.char(255),false) and not H.record(host,string.rep('x',4097),false)
    and not H.record(host,'valid',nil),'invalid keyword or mode saved')
local stale,stale_owner,stale_original=list,owner,original
expect(H.record(host,'new',false),'concurrent new search not saved')
expect(not H.remove(host,stale,stale_owner,stale_original,1) and not H.clear(host,stale,stale_owner,stale_original),
    'stale deletion discarded newer search')
list,_,owner,original=H.list(host)
expect(H.remove(host,list,owner,original,2),'current entry removal failed')
list,_,owner,original=H.list(host);expect(#list.entries==19 and list.entries[1].keyword=='new','removal damaged others')
account='b';expect(#H.list(host).entries==0,'account history leaked')
expect(not H.clear(host,list,owner,original),'old account cleared new account')
expect(H.record(host,'private B',false),'second account could not save')
account='a';expect(H.list(host).entries[1].keyword=='new','switching accounts lost history')
list,_,owner,original=H.list(host);expect(H.clear(host,list,owner,original) and #H.list(host).entries==0,'clear failed')
account=nil;expect(H.record(host,'guest',true) and H.list(host).entries[1].keyword=='guest','guest session history failed')
account='b';expect(H.list(host).entries[1].keyword=='private B','guest history leaked into account')
account=nil;list,_,owner,original=H.list(host);account='b'
expect(not H.clear(host,list,owner,original),'guest stale clear crossed login')
account='a';local compare=db.compareProfileState
db.compareProfileState=function() account='b';return false end
expect(not H.record(host,'old account only',false) and H.list(host).entries[1].keyword=='private B',
    'retry moved a search to a different account')
db.compareProfileState=compare
account='a';values.a={schema=1,entries={{keyword='broken\n',public=false}}}
expect(select(2,H.list(host))=='storage' and not H.record(host,'safe',false),'corrupt history was overwritten')
values.a={schema=1,entries={{public=true}}}
expect(select(2,H.list(host))=='storage' and not H.record(host,'safe',false),'missing keyword broke corrupt-history protection')
print('recent_searches_spec: '..checks..' checks')
