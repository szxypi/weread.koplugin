-- Copyright (C) 2026 MiuRead contributors. AGPL-3.0-only.
-- Ported from MiuRead c1893562 readtime_protocol.lua with strict validation.
-- Signature transform references AnkioTomas/moon 43b2181 (GPL-3.0).
-- Attribution and license: integrations/licenses/readtime-sources.txt.
-- Pure protocol only. Callers must separately prove ledger/file ownership,
-- overlap exclusion and durable dispatch; this module performs no network I/O.
local Crypto=require('weread.lib.crypto')
local bit=require('bit')
local M={}
local DEFAULT_GUEST_TOKEN='5ecdcfd7f' -- Public client constant, never account authentication.
local REMAP={
52,202,85,64,29,182,147,198,49,48,41,53,50,167,184,17,
    194,181,22,250,139,177,36,164,16,144,4,233,8,248,59,138,
    156,140,68,249,188,92,105,226,161,218,210,211,117,137,247,30,
    45,80,86,215,114,83,191,34,251,32,15,1,46,69,135,110,
    102,72,242,224,205,254,103,169,67,244,148,81,206,165,74,238,
    19,38,142,204,170,51,20,93,14,57,187,207,145,43,129,77,
    234,153,236,26,44,133,197,217,54,116,75,24,225,241,61,157,
    65,159,180,23,13,214,76,190,220,175,151,40,119,240,98,255,
    113,193,200,39,143,108,104,168,155,230,89,28,27,18,9,152,
    78,63,6,55,0,186,31,10,25,47,201,213,208,87,73,111,
    253,37,228,97,12,66,203,150,100,95,219,173,96,35,141,154,
    109,195,196,94,62,185,146,106,189,91,7,127,118,149,237,79,
    171,132,122,128,231,120,199,229,235,115,131,107,252,56,70,125,
    71,101,179,82,99,58,5,209,239,163,166,222,158,60,2,174,
    178,123,160,246,243,42,192,172,134,3,90,84,11,245,130,212,
    126,227,223,176,216,221,33,232,124,136,162,121,88,112,183,21,
}
local function integer(v,low,high)
    return type(v)=='number' and v==v and v%1==0 and v>=low and v<=high
end
local function bounded(v,maximum) return type(v)=='string' and #v>0 and #v<=maximum end
local function dense(rows,maximum)
    assert(type(rows)=='table' and #rows>0 and #rows<=maximum,'readtime/rows')
    local count=0
    for key in pairs(rows) do assert(integer(key,1,#rows),'readtime/rows');count=count+1 end
    assert(count==#rows,'readtime/rows')
end
function M.zone(value)
    assert(type(value)=='string' and value:match('^[+-]%d%d:%d%d$'),'readtime/zone')
    local hour,minute=tonumber(value:sub(2,3)),tonumber(value:sub(5,6))
    assert(hour<=14 and minute<=59 and (hour<14 or minute==0),'readtime/zone');return value
end
function M.time_zone(stamp)
    stamp=stamp or os.time()
    local raw=os.date('%z',stamp);assert(raw and raw:match('^[+-]%d%d%d%d$'),'readtime/zone')
    local minutes=(tonumber(raw:sub(2,3))*60+tonumber(raw:sub(4,5)))*(raw:sub(1,1)=='-' and -1 or 1)
    local fields=os.date('*t',stamp)
    if fields.isdst then fields.isdst=false;minutes=minutes-(assert(os.time(fields))-stamp)/60 end
    assert(minutes%1==0,'readtime/zone');local absolute=math.abs(minutes)
    return M.zone(string.format('%s%02d:%02d',minutes<0 and '-' or '+',math.floor(absolute/60),absolute%60))
end
function M.guest_token(feature)
    assert(type(feature)=='table' and type(feature.feature)=='table','readtime/feature')
    local value=feature.feature.guest_token
    if value==nil or value=='' then return DEFAULT_GUEST_TOKEN,'client_default' end
    assert(bounded(value,4096),'readtime/guest');return value,'remote'
end
local function rotate(value)
    local checksum=0;for i=1,#value do checksum=bit.bxor(checksum,value:byte(i)) end
    local offset=(checksum%11)%#value
    return offset==0 and value or value:sub(#value-offset+1)..value:sub(1,#value-offset)
end
local function byte_less(a,b)
    for i=1,math.min(#a,#b) do if a:byte(i)~=b:byte(i) then return a:byte(i)<b:byte(i) end end
    return #a<#b
end
function M.sign(parts)
    dense(parts,64);local values={'5a6f1'}
    for _i,part in ipairs(parts) do
        assert(type(part)=='string' and #part<=32768,'readtime/sign')
        values[#values+1]=part:gsub('.',function(c) return string.char(REMAP[c:byte()+1]) end)
    end
    table.sort(values,byte_less)
    return Crypto.sha256_hex(rotate(Crypto.sha256_hex(rotate(table.concat(values)))))
end
function M.validate_rows(rows,book_id,now)
    assert(bounded(book_id,20) and book_id:match('^[1-9]%d*$') and integer(now,1,4102444800),'readtime/identity_clock')
    dense(rows,100);local sorted={};local keys={start_time=true,duration=true,time_zone=true,book_version=true}
    for _i,row in ipairs(rows) do
        assert(type(row)=='table','readtime/rows');local count=0
        for key in pairs(row) do assert(keys[key],'readtime/rows');count=count+1 end
        assert(count==4 and integer(row.start_time,1,4102444800) and integer(row.duration,1,60)
            and integer(row.book_version,1,2147483647) and row.start_time+row.duration<=now,'readtime/rows')
        M.zone(row.time_zone);sorted[#sorted+1]=row
    end
    table.sort(sorted,function(a,b) return a.start_time<b.start_time end)
    local version,total,previous=nil,0,0
    for _i,row in ipairs(sorted) do
        assert(row.start_time>=previous and (not version or version==row.book_version),'readtime/mixed_source')
        version=row.book_version;previous=row.start_time+row.duration;total=total+row.duration
    end
    assert(total<=600,'readtime/batch_limit');return total,version
end
function M.hours(rows)
    local buckets,keys={},{}
    for _i,row in ipairs(rows) do
        local at,left=row.start_time,row.duration;local zone=M.zone(row.time_zone)
        while left>0 do
            local hour=at-at%3600;local seconds=math.min(left,hour+3600-at);local key=hour..zone
            if not buckets[key] then
                buckets[key]={startOfHour=hour,timeZone=zone,readingTime=0,ttsTime=0};keys[#keys+1]=key
            end
            local bucket=buckets[key];bucket.readingTime=bucket.readingTime+seconds
            assert(bucket.readingTime<=3600,'readtime/hour_limit');at=at+seconds;left=left-seconds
        end
    end
    table.sort(keys,function(a,b)
        local x,y=buckets[a],buckets[b]
        return x.startOfHour==y.startOfHour and x.timeZone<y.timeZone or x.startOfHour<y.startOfHour
    end)
    local result={};for _i,key in ipairs(keys) do result[#result+1]=buckets[key] end;return result
end
function M.batch(credentials,book_id,rows,guest,config_token,now,random,envelope)
    assert(type(credentials)=='table' and bounded(credentials.vid,32) and credentials.vid:match('^[1-9]%d*$')
        and bounded(credentials.deviceId,32) and #credentials.deviceId==32
        and bounded(credentials.accessToken,8192) and bounded(credentials.refreshToken,8192),'readtime/credentials')
    local total,version=M.validate_rows(rows,book_id,now);envelope=envelope or {}
    local stamp,outer_random=envelope.timestamp or now*1000,envelope.random or random
    local zone=M.zone(envelope.current_zone or M.time_zone(now))
    assert(integer(random,0,999) and integer(outer_random,0,999) and integer(stamp,1000,4102444800999)
        and stamp-now*1000>=0 and stamp-now*1000<2000 and bounded(guest,4096) and bounded(config_token,4096),'readtime/parameters')
    local buckets=M.hours(rows)
    local book={bookId=book_id,bookVersion=version,appId='',deviceId=credentials.deviceId,installId='',summary='',
        progress=0,currentProgress=0,autoTime=0,isLecture=0,isResendReadingInfo=1,lectureTime=0,lectureTextTime=0,
        novalTime=0,ttsTime=0,finish=false,risk=0,readingTime=total,recordCreateTimeZone=zone,timestamp=now,random=random,hours=buckets}
    local parts={credentials.vid,book.deviceId,'',book_id,'0',zone,tostring(total),'0'}
    for _i,hour in ipairs(buckets) do
        parts[#parts+1]=table.concat({hour.startOfHour,hour.timeZone,hour.readingTime,hour.ttsTime},'_')
    end
    book.signature=M.sign({guest,tostring(random),tostring(now),table.concat(parts,'_')})
    return {books={book},timestamp=stamp,random=outer_random,
        signature=Crypto.sha256_hex(string.format('%.0f',stamp)..config_token..tostring(outer_random))}
end
return M
