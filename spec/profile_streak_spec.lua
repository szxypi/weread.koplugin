package.path='./?.lua;./?/init.lua;'..package.path
local Profile=require('weread.lib.profile')
local Stats=require('weread.lib.read_stats')
local DAY=86400
-- The previous day-by-day implementation is retained as a test oracle.
local function reference(months,now)
    months=type(months)=='table' and months or {}
    local today,count=Profile.day(now),0
    local cursor=today
    local current=months[tostring(Stats.period_start('monthly',cursor))]
    if type(current)~='table' or type(current.daily)~='table' then
        return 0,true,Stats.period_start('monthly',cursor)
    end
    if (current.daily[tostring(cursor)] or 0)<=0 then cursor=cursor-DAY end
    for _=1,24*366 do
        local base=Stats.period_start('monthly',cursor)
        local month=months[tostring(base)]
        if type(month)~='table' or type(month.daily)~='table' then return count,true,base end
        if (month.daily[tostring(cursor)] or 0)<=0 then return count,false end
        count,cursor=count+1,cursor-DAY
    end
    return count,true
end
local function equal(months,now)
    local a,b,c=reference(months,now)
    local x,y,z=Profile.streak(months,now)
    assert(a==x and b==y and c==z,'streak or missing-month boundary changed')
end
local now=Stats.cst_time{year=2025,month=3,day=1,hour=12}
local today=Profile.day(now)
local current=Stats.period_start('monthly',now)
local months={}
for i=0,310 do
    local base=Stats.shift_period('monthly',current,-i)
    local ending=Stats.shift_period('monthly',base,1)
    local daily={}
    for stamp=base,ending-DAY,DAY do daily[tostring(stamp)]=60 end
    months[tostring(base)]={daily=daily}
end
for day=0,2000,17 do
    local stamp=today-day*DAY+12*3600
    equal(months,stamp)
    local base=Stats.period_start('monthly',stamp)
    local month=months[tostring(base)]
    local key=tostring(Profile.day(stamp))
    local old=month.daily[key];month.daily[key]=0;equal(months,stamp);month.daily[key]=old
    months[tostring(base)]=nil;equal(months,stamp);months[tostring(base)]=month
end
for _,offset in ipairs({1,2,28,29,30,31,365,366,729,8783,8784}) do
    local stamp=today-offset*DAY
    local base=Stats.period_start('monthly',stamp)
    local key=tostring(stamp);local old=months[tostring(base)].daily[key]
    months[tostring(base)].daily[key]=0;equal(months,now);months[tostring(base)].daily[key]=old
    local removed=months[tostring(base)];months[tostring(base)]=nil;equal(months,now);months[tostring(base)]=removed
end
equal(nil,now)
local count,lower,missing=Profile.streak(months,now)
assert(count==24*366 and lower and missing==nil,'maximum streak bound changed')
local original=Stats.period_start;local conversions=0
Stats.period_start=function(...) conversions=conversions+1;return original(...) end
Profile.streak(months,now)
Stats.period_start=original
assert(conversions==1,'month was recalculated for each day')
print('profile_streak_spec: cross-month, leap, missing and maximum streak comparisons passed')
