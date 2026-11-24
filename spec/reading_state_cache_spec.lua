package.path='./?.lua;'..package.path
local Store=require('weread.lib.reading_state_cache')
local account='account-a';local rows={};local count=0
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function clone(a)
    if type(a)~='table' then return a end
    local out={};for k,v in pairs(a) do out[k]=clone(v) end;return out
end
local library={accountKey=function() return account end}
function library:getProfileState(key) return clone(rows[account..key]) end
function library:compareProfileState(key,expected,value)
    local path=account..key
    if not same(rows[path],expected) then return false end
    rows[path]=clone(value);return true
end
local now=1234
local function nonce() count=count+1;return string.format('%032x',count) end
local cache=Store:new(library,account,{now=function() return now end,nonce=nonce})
assert(cache:read('41')==nil)
assert(cache:write('41',false,nil))
local first=assert(cache:read('41'));assert(first.started==false and first.checked_at==1234)
assert(not cache:write('41',true,nil),'absent expectation replaced existing observation')
now=1235;assert(cache:write('41',true,first));local second=assert(cache:read('41'))
assert(second.started and second.checked_at==1235 and second.revision~=first.revision)
assert(not cache:write('41',false,first),'stale observation replaced a newer result')
assert(cache:write('CB_abc',true,nil));assert(cache:read('CB_abc').started)
local imported=cache:read('CB_abc');assert(cache:write('CB_abc','missing',imported))
assert(cache:read('CB_abc').started=='missing')
assert(not cache:write('0',true,nil) and not cache:write('41',1,second))
assert(not cache:write('41',false,cache:read('CB_abc')),'foreign book expectation accepted')
account='account-b';assert(not cache:read('41') and not cache:write('41',false,second))
local other=Store:new(library,account,{now=function() return now end,nonce=nonce})
assert(not other:read('41') and other:write('41',false,nil));assert(not other:read('CB_abc'))
account='account-a';assert(cache:read('41').started)
for path,value in pairs(rows) do if value.account=='account-a' and value.book_id=='41' then
    rows[path]={schema=1,account='account-a',book_id='41',started=true,checked_at=now,revision='invalid'};break
end end
assert(not cache:read('41') and not cache:write('41',true,nil),'corrupt row was replaced')
local fixed=Store:new(library,account,{now=function() return 0 end,nonce=nonce})
assert(not fixed:write('55',true,nil),'invalid timestamp accepted')
local reused=Store:new(library,account,{now=function() return now end,nonce=function() return second.revision end})
assert(not reused:write('41',true,second),'revision reused')
print('PASS: started-reading cache isolation, compare-and-swap and corruption')
