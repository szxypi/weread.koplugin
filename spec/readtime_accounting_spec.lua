package.path='./?.lua;'..package.path
local M=require('weread.lib.readtime_accounting');local Stats=require('weread.lib.read_stats')
local F=require('spec.helpers.thought_edit_fixture')
local n=0;local function expect(v) n=n+1;assert(v,'check '..n) end
local now=1700007200;local old=now-86400;local day=M.day(old);local month=tostring(Stats.period_start('monthly',old))
local rows={{start_time=old,duration=2,time_zone='+08:00',book_version=7}}
local window=M.window(rows,'42',now);expect(window.seconds==2 and window.version==7 and window.day==day)
local meta={seconds=2,day=day,counts={readingTime=20,recordReadingTime=0,ttsTime=0},months={
    [month]={baseTime=tonumber(month),readTimes={[tostring(day)]=5,[month]=0},totalReadTime=5,readDays=1}}}
expect(M.check(meta,meta.counts,meta.months).kind=='before')
local target=M.expected(meta)[1];target[month].readTimes[month]=nil
local counts=F.clone(meta.counts);counts.readingTime=22
expect(M.check(meta,counts,target).kind=='target' and M.check(meta,counts,target).removed_zero_buckets==1)
expect(M.check(meta,meta.counts,target).kind=='lagging');expect(M.check(meta,counts,meta.months).kind=='lagging')
local wrong=F.clone(target);wrong[month].readTimes[tostring(day)]=5;wrong[month].readTimes[tostring(M.day(now))]=2
expect(M.check(meta,counts,wrong)==nil)
wrong=F.clone(target);wrong[month].readTimes[tostring(tonumber(month)+3*86400)]=0
expect(M.check(meta,counts,wrong)==nil)
local current_meta=F.clone(meta);current_meta.protocol='native-current-time-cst-v1'
expect(M.check(current_meta,counts,wrong).kind=='target' and M.check(current_meta,counts,wrong).added_zero_buckets==1)
wrong=F.clone(counts);wrong.ttsTime=1;expect(M.check(meta,wrong,target)==nil)
for _i,kind in ipairs({'today','zone','cross_day'}) do
    local v=F.clone(rows)
    if kind=='today' then v[1].start_time=now-2 end
    if kind=='zone' then v[1].time_zone='+00:00' end
    if kind=='cross_day' then v[1].start_time=day+86399 end
    expect(not pcall(M.window,v,'42',now))
end
local today={{start_time=now-2,duration=2,time_zone='+08:00',book_version=7}}
expect(M.window(today,'42',now,true).day==M.day(now))
expect(not pcall(M.window,rows,'42',now,true))
expect(not pcall(M.window,today,'CB_Synthetic',now,true))
local wrong_zone=F.clone(today);wrong_zone[1].time_zone='+00:00'
expect(not pcall(M.window,wrong_zone,'42',now,true))
expect(meta.months[month].readTimes[month]==0 and meta.months[month].totalReadTime==5)
print('readtime_accounting_spec: '..n..' checks')
