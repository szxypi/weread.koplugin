-- Native zero-time position fields verified by Python and actual TXT reads.
-- Signature source/attribution: integrations/licenses/readtime-sources.txt.
-- Pure DTO only; no network, persistence, renewal or dispatch authority.
local Signing=require('weread.lib.readtime_protocol')
local Text=require('weread.lib.protocol')
local Remote=require('weread.lib.remote_progress')
local Hash=require('weread.lib.thought_edit_contract')
local M={}
local function fail(reason) error('native_position/'..reason,0) end
function M.integer(value,low,high)
    return type(value)=='number' and value==value and value%1==0 and value>=low and value<=high
end
function M.id(value)
    if type(value)=='number' and M.integer(value,1,9007199254740991) then value=string.format('%.0f',value) end
    return type(value)=='string' and #value<=20 and value:match('^[1-9]%d*$') and value or nil
end
function M.summary(value)
    if type(value)~='string' or #value==0 or #value>2048 or Text.utf8_substr(value,#value)~=value
        or Text.utf8_substr(value,512)~=value then return false end
    for index=1,#value do local byte=value:byte(index);if byte<32 and byte~=9 and byte~=10 and byte~=13 then return false end end
    return true
end
local function token(value)
    return type(value)=='string' and #value>=8 and #value<=4096 and not value:find('[^!-~]') and not value:find('[;"\\]')
end
function M.credentials(value)
    return type(value)=='table' and type(value.vid)=='string' and M.id(value.vid)~=nil
        and type(value.deviceId)=='string' and #value.deviceId==32 and value.deviceId:match('^eink334691225%d+$')~=nil
        and token(value.accessToken) and token(value.refreshToken)
end
function M.point(value)
    if type(value)~='table' or not M.id(value.book_id) or not M.id(value.chapter_uid)
        or not M.integer(tonumber(M.id(value.chapter_uid)),1,9007199254740991)
        or not M.integer(value.chapter_idx,0,1000000) or not M.integer(value.chapter_offset,0,2147483647)
        or type(value.raw_percent)~='number' or value.raw_percent~=value.raw_percent or value.raw_percent<0 or value.raw_percent>100
        or not M.summary(value.summary) then fail('point') end
    return {book_id=M.id(value.book_id),chapter_uid=M.id(value.chapter_uid),chapter_idx=value.chapter_idx,
        chapter_offset=value.chapter_offset,raw_percent=value.raw_percent,summary=value.summary}
end
function M.equal(first,second)
    local ok,a,b=pcall(function() return M.point(first),M.point(second) end)
    if not ok then return false end
    for key,value in pairs(a) do if value~=b[key] then return false end end;return true
end
function M.point_hash(value)
    local p=M.point(value)
    return Hash.digest({'native-position-v1',p.book_id,p.chapter_uid,p.chapter_idx,p.chapter_offset,string.format('%.17g',p.raw_percent),p.summary})
end
function M.counts(value)
    if type(value)~='table' then fail('counts') end
    local out={}
    for _i,key in ipairs({'readingTime','recordReadingTime','ttsTime'}) do
        if not M.integer(value[key],0,9007199254740991) then fail('counts') end;out[key]=value[key]
    end
    return out
end
function M.same_counts(first,second)
    local ok,a,b=pcall(function() return M.counts(first),M.counts(second) end)
    if not ok then return false end;for key,value in pairs(a) do if b[key]~=value then return false end end;return true
end
function M.snapshot(raw,id)
    local p,reason,provided=Remote.project(raw,id,'native');local node=Remote.node(raw,id)
    if reason or not p or not node or not provided.chapter_uid or not provided.chapter_idx or not provided.chapter_offset
        or type(node.summary)~='string' then fail('response') end
    p.summary=node.summary;return {position=M.point(p),counts=M.counts(node)}
end
function M.confirmed(value)
    if type(value)~='table' then return false end
    for _i,key in ipairs({'errcode','errCode'}) do if value[key]~=nil and value[key]~=0 then return false end end
    return value.succ==true or value.succ==1
end
function M.body(credentials,point,version,guest,now,random,zone,chapter_progress,empty_array)
    assert(M.credentials(credentials),'native_position/credentials');point=M.point(point)
    assert(M.integer(version,0,2147483647) and M.integer(now,1,4102444800) and M.integer(random,0,999)
        and type(guest)=='string' and #guest>0 and #guest<=4096 and type(empty_array)=='table' and next(empty_array)==nil,'native_position/parameters')
    zone=Signing.zone(zone)
    local value={appId=credentials.deviceId,autoTime=0,bookId=point.book_id,bookVersion=version,chapterIdx=point.chapter_idx,
        chapterOffset=point.chapter_offset,chapterUid=tonumber(point.chapter_uid),currentProgress=point.raw_percent,deviceId=credentials.deviceId,
        hours=empty_array,installId='',isLecture=0,isStoryFeed=0,lectureTextTime=0,lectureTime=0,novalTime=0,random=random,readingTime=0,
        recordCreateTimeZone=zone,reviewId='',risk=0,sourceModule='unknown',summary=point.summary,timestamp=now,ttsTime=0,wordCount=0}
    if chapter_progress~=nil then
        assert(type(chapter_progress)=='number' and chapter_progress==chapter_progress and chapter_progress>=0 and chapter_progress<=100,'native_position/chapter_progress')
        value.chapterProgress=chapter_progress
    end
    local parts={credentials.vid,value.deviceId,value.appId,value.bookId,'0',zone,'0','0'}
    value.signature=Signing.sign({guest,tostring(random),string.format('%.0f',now),table.concat(parts,'_')});return value
end
return M
