-- Exact monthly duration comparison; audit removal of existing zero buckets.
-- This pure helper grants no network, queue or receipt authority.
local Data=require('weread.lib.statistics_data')
local Stats=require('weread.lib.read_stats')
local M={}
local FIELDS={baseTime=true,readTimes=true,totalReadTime=true,readDays=true}
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
function M.validate(months)
    assert(type(months)=='table','time_statistics/months')
    local count=0
    for key,row in pairs(months) do
        count=count+1
        assert(type(key)=='string' and #key>=9 and #key<=10 and key:match('^[1-9]%d*$'),'time_statistics/schema')
        local stamp=tonumber(key)
        assert(stamp<=4102444800 and Stats.period_start('monthly',stamp)==stamp and type(row)=='table','time_statistics/schema')
        for k in pairs(row) do assert(FIELDS[k],'time_statistics/schema') end
        for k in pairs(FIELDS) do assert(row[k]~=nil,'time_statistics/schema') end
        local normalized=Data.project(row,'monthly',stamp)
        assert(equal(normalized,row),'time_statistics/canonical')
    end
    assert(count>=1 and count<=2,'time_statistics/months');return months
end
function M.compare(expected,observed)
    M.validate(expected);M.validate(observed)
    local removed=0
    for month,left in pairs(expected) do
        local right=observed[month]
        if not right then return nil end
        for key in pairs(FIELDS) do if key~='readTimes' and left[key]~=right[key] then return nil end end
        for key,value in pairs(right.readTimes) do if left.readTimes[key]==nil or left.readTimes[key]~=value then return nil end end
        for key,value in pairs(left.readTimes) do
            if right.readTimes[key]==nil then
                if value~=0 then return nil end
                removed=removed+1
            end
        end
    end
    for month in pairs(observed) do if not expected[month] then return nil end end
    return {removed_zero_buckets=removed}
end
return M
