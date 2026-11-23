-- One-day CST attribution, independently checked counters and sparse zeros.
local C=require('weread.lib.readtime_transfer_contract')
local P=require('weread.lib.native_position_protocol')
local Wire=require('weread.lib.readtime_protocol')
local Stats=require('weread.lib.readtime_statistics')
local Dates=require('weread.lib.read_stats')
local M={}
function M.day(stamp) return math.floor((stamp+28800)/86400)*86400-28800 end
local function copy(v) if type(v)~='table' then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
function M.window(rows,book,now,current_day)
    local seconds,version
    if C.cb_id(book) then seconds,version=Wire.validate_cb_rows(rows,book,now)
    else seconds,version=Wire.validate_rows(rows,book,now) end
    local first=M.day(rows[1].start_time)
    assert(current_day==true and C.id(book) and first==M.day(now)
        or not current_day and first<M.day(now),'readtime_accounting/day')
    for _i,row in ipairs(rows) do
        assert(row.time_zone=='+08:00' and M.day(row.start_time)==first and M.day(row.start_time+row.duration-1)==first,
            'readtime_accounting/day_zone')
    end
    return {seconds=seconds,version=version,day=first,months={
        [tostring(Dates.period_start('monthly',first))]=true,[tostring(Dates.period_start('monthly',now))]=true}}
end
function M.validate(metadata)
    assert(type(metadata)=='table' and C.integer(metadata.seconds,1,600) and C.integer(metadata.day,1,4102444800),'readtime_accounting/metadata')
    P.counts(metadata.counts);assert(metadata.counts.readingTime<=2^53-1-metadata.seconds,'readtime_accounting/counter_limit')
    Stats.validate(metadata.months)
    local month=tostring(Dates.period_start('monthly',metadata.day))
    assert(metadata.months[month] and M.day(metadata.day)==metadata.day,'readtime_accounting/month');return month
end
function M.expected(metadata)
    local month=M.validate(metadata);local target=copy(metadata.months);local stat=target[month];local day=tostring(metadata.day)
    stat.readTimes[day]=(stat.readTimes[day] or 0)+metadata.seconds;stat.totalReadTime=stat.totalReadTime+metadata.seconds
    local second=copy(target);second[month].readDays=second[month].readDays+1
    return {target,second}
end
function M.check(metadata,counts,months)
    local month=M.validate(metadata);P.counts(counts);Stats.validate(months)
    local base=P.same_counts(metadata.counts,counts)
    local expected=copy(metadata.counts);expected.readingTime=expected.readingTime+metadata.seconds
    local target=P.same_counts(expected,counts)
    if not base and not target then return nil end
    local unchanged=Stats.compare(metadata.months,months)
    local matched
    for _i,candidate in ipairs(M.expected(metadata)) do
        local result=Stats.compare(candidate,months)
        if result then matched=result;matched.read_days_delta=months[month].readDays-metadata.months[month].readDays end
    end
    if target and matched then matched.kind='target';return matched end
    if base and unchanged then return {kind='before'} end
    if base and matched or target and unchanged then return {kind='lagging'} end
end
return M
