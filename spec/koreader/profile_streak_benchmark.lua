require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local old=assert(loadfile(arg[2]))()
local current=require('weread.lib.profile')
local Stats=require('weread.lib.read_stats')
local now=os.time();local base=Stats.period_start('monthly',now)
local months={}
for i=0,310 do
    local month=Stats.shift_period('monthly',base,-i)
    local ending=Stats.shift_period('monthly',month,1)
    local daily={}
    for stamp=month,ending-86400,86400 do daily[tostring(stamp)]=600 end
    months[tostring(month)]={daily=daily}
end
local short={}
for i=0,23 do
    local month=Stats.shift_period('monthly',base,-i)
    short[tostring(month)]=months[tostring(month)]
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local expected={old.streak(short,now)}
local limit={old.streak(months,now)}
assert(equal(expected,{current.streak(short,now)}) and equal(limit,{current.streak(months,now)}))
local result={result='PASS',iterations=100,cases={},fetch={}}
for _,mode in ipairs({{'baseline',old},{'optimized',current}}) do
    local name,profile=mode[1],mode[2]
    result.cases[name]={}
    for _,fixture in ipairs({{'two_years',short,expected},{'maximum',months,limit}}) do
        local calls,shifts=0,0;local period,shift=Stats.period_start,Stats.shift_period
        Stats.period_start=function(...) calls=calls+1;return period(...) end
        Stats.shift_period=function(...) shifts=shifts+1;return shift(...) end
        local values={profile.streak(fixture[2],now)}
        Stats.period_start=period;Stats.shift_period=shift
        assert(equal(values,fixture[3]),'streak result changed')
        local started=os.clock()
        for _=1,100 do assert(equal({profile.streak(fixture[2],now)},fixture[3])) end
        result.cases[name][fixture[1]]={seconds=os.clock()-started,period_conversions=calls,month_transitions=shifts,
            days=values[1],lower_bound=values[2]}
    end
    local requests=0
    local client={get_read_stats=function(_,_,month)
        requests=requests+1
        local value=assert(months[tostring(month)])
        return {baseTime=month,readTimes=value.daily,_stats_source='synthetic'}
    end}
    local context={checkCancelled=function() end,emit=function() end}
    local started=os.clock();local value=profile.fetch(client,context,now)
    result.fetch[name]={seconds=os.clock()-started,requests=requests,months=value.months,
        fetched_at=value.fetched_at,source_kind=value.source_kind}
end
assert(equal(result.fetch.baseline.months,result.fetch.optimized.months)
    and result.fetch.baseline.requests==24 and result.fetch.optimized.requests==24,
    'fetch changed monthly results or request count')
result.fetch.baseline.months=nil;result.fetch.optimized.months=nil
io.write('\nWEREAD_PROFILE_STREAK='..require('json').encode(result)..'\n')
