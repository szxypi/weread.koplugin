package.path='./?.lua;'..package.path
local M=require('weread.lib.readtime_statistics')
local clone=require('spec.helpers.thought_edit_fixture').clone
local count=0;local function expect(v) count=count+1;assert(v,'check '..count) end
local month='1698768000';local first=tonumber(month);local a=tostring(first+86400);local b=tostring(first+172800)
local expected={[month]={baseTime=first,readTimes={[month]=9,[a]=0,[b]=0},totalReadTime=9,readDays=1}}
local before=clone(expected);expect(M.compare(expected,before).removed_zero_buckets==0)
before[month].readTimes[a]=nil;expect(M.compare(expected,before).removed_zero_buckets==1)
before[month].readTimes[b]=nil;expect(M.compare(expected,before).removed_zero_buckets==2)
expect(expected[month].readTimes[a]==0 and expected[month].readTimes[b]==0)
local extra=clone(expected);extra[month].readTimes[tostring(first+3*86400)]=0
expect(M.compare(expected,extra)==nil)
expect(M.compare(expected,extra,true).added_zero_buckets==1)
extra[month].readTimes[tostring(first+4*86400)]=0
expect(M.compare(expected,extra,true).added_zero_buckets==2)
extra[month].readTimes[tostring(first+5*86400)]=0
expect(M.compare(expected,extra,true)==nil)
extra=clone(expected);extra[month].readTimes[tostring(first+3*86400)]=1
expect(M.compare(expected,extra,true)==nil)
for _i,change in ipairs({function(v) v[month].readTimes[tostring(first+3*86400)]=0 end,
    function(v) v[month].readTimes[month]=nil end,function(v) v[month].readTimes[month]=10 end,
    function(v) v[month].readTimes[a]=1 end,function(v) v[month].totalReadTime=11 end,
    function(v) v[month].readDays=2 end}) do
    local value=clone(expected);change(value);expect(M.compare(expected,value)==nil)
end
for _i,change in ipairs({function(v) v[month].extra=true end,function(v) v[month].readTimes[a]=false end,
    function(v) v[month].readTimes['0'..a]=0 end,function(v) v[month].readTimes[tostring(first+1)]=0 end,
    function(v) v[month].readTimes[a]=-1 end,function(v) v[month].totalReadTime=0/0 end}) do
    local value=clone(expected);change(value);expect(not pcall(M.validate,value))
end
print('readtime_statistics_spec: '..count..' checks')
