package.path='./?.lua;'..package.path
local array_mt={};local null=function() end
local changed,mixed,valid,calls=false,false,true,{}
local function progress(counter)
    return {bookId='456',book={bookId='456',title='Synthetic',readingTime=counter or 0},canFreeRead=1,timestamp=100}
end
local function recorded()
    return {bookId='456',progress=5,chapterUid=7,chapterIdx=1,chapterOffset=2,summary='Text',
        readingTime=10,recordReadingTime=10,ttsTime=0}
end
local function shelf() return {books={{bookId='456',isTop=0,secret=0,finishReading=0}},archive={}} end
package.loaded['weread.lib.native_read_access']={matches=function() return valid end}
package.loaded['weread.lib.read_access']={matches=function() return valid end}
package.loaded['weread.lib.native_authorization']={new=function(_self,_client,options)
    assert(options.expected_vid=='123')
    return {_request=function(_object,stage,url,body,credentials)
        assert(options.is_current() and stage=='translation_progress' and url=='https://i.weread.qq.com/book/getProgress?bookId=456'
            and not body and credentials.vid=='123')
        calls[#calls+1]='native_progress';return progress(changed and #calls>4 and 1 or 0)
    end,read_shelf=function() calls[#calls+1]='native_shelf';return shelf() end,cancel=function() end}
end}
local Baseline=require('weread.lib.translation_generation_baseline')
local client={json_decode=function(_self,value) if value=='null' then return null elseif value=='[]' then return setmetatable({},array_mt) end end,
    get_progress_snapshot=function(_self,id,web,flags)
        calls[#calls+1]='web_progress';assert(id=='456' and web.cookies.wr_vid=='123' and flags.fresh)
        return mixed and recorded() or progress(changed and #calls>4 and 1 or 0)
    end,get_web_shelf=function(_self,cookies) calls[#calls+1]='web_shelf';assert(cookies.wr_vid=='123');return shelf() end}
local selected={scope={vid='123'},credentials={vid='123',accessToken='synthetic-access',refreshToken='synthetic-refresh',
    deviceId='eink3346912251234567890123456789'}}
local web={web={cookies={wr_vid='123'}}};local options={is_current=function() return true end}
local result,reason=Baseline.stable(client,{},selected,web,'456',options)
assert(result and not result.position_present and #result.digest==64 and #calls==8,reason or 'missing two observations')
calls={};changed=true;local value,why=Baseline.stable(client,{},selected,web,'456',options)
assert(not value and why=='changed','changed counter accepted across observations')
changed=false;calls={};mixed=true;assert(not Baseline.read(client,{},selected,web,'456',options),'mixed position presence accepted')
mixed=false;calls={};valid=false;assert(not Baseline.read(client,{},selected,web,'456',options) and #calls==0,'stale login made requests')
valid=true;calls={};web.web.cookies.wr_vid='999'
assert(not Baseline.read(client,{},selected,web,'456',options) and #calls==0,'wrong Web account made requests')
print('PASS: translation baseline read-only transport and repeated observations')
