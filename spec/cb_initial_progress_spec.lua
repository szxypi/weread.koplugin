package.path='./?.lua;'..package.path
local Access=require('weread.lib.source_currentness')
local Native=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local State=require('weread.lib.cb_initial_state')
local Readback=require('weread.lib.progress_readback')
local Progress=require('weread.lib.cb_initial_progress')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local id='CB_SyntheticFirst'
local creds={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
local web_access={web={cookies={wr_vid=creds.vid}}}
local native_access={credentials=creds,scope={vid=creds.vid,epoch=1}}
local old_capture,old_matches,old_native,old_new=Access.capture,Access.matches_cb_initial_access,Native.capture,Auth.new
local valid=true
Access.capture=function() return web_access end
Native.capture=function() return native_access end
Access.matches_cb_initial_access=function(_settings,w,n) return valid and w==web_access and n==native_access end
local raw={book={bookId=id,chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0,summary='',updateTime=1,
    readingTime=0,recordReadingTime=0,ttsTime=0}}
local web,native=copy(raw),copy(raw)
local requests={}
local client={get_web_progress=function(_self,book,opts)
    expect(book==id and opts.sensitive==true,'Web read lost scope');requests[#requests+1]='web';return copy(web)
end}
Auth.new=function(_self,_client,options)
    expect(options.expected_vid==creds.vid and options.is_current(),'native account scope missing')
    return {_request=function(_auth,stage,url,body,received)
        expect(stage=='position_progress' and url=='https://i.weread.qq.com/book/getProgress?bookId='..id
            and body==nil and received==creds,'native progress escaped read scope')
        requests[#requests+1]='native';return copy(native)
    end,cancel=function() end}
end
local settings={}
local current=function() return true end
local access=assert(Progress.capture(settings))
local initial=assert(State.from(raw,id))
expect(Progress.before(client,settings,access,initial,current)~=nil and #requests==2,'valid baseline rejected')
web.book.updateTime=2
expect(not Progress.before(client,settings,access,initial,current),'changed Web baseline accepted')
web=copy(raw);native.book.readingTime=1
expect(not Progress.before(client,settings,access,initial,current),'nonzero native time accepted')
native=copy(raw);native.book.chapterUid=11
expect(not Progress.before(client,settings,access,initial,current),'positive native chapter accepted as empty')
native=copy(raw);valid=false;requests={}
expect(not Progress.before(client,settings,access,initial,current) and #requests==0,'stale auth sent reads')
valid=true
expect(not Progress.before(client,settings,access,initial,function() return false end),'stale source accepted')
local position={book_id=id,chapter_uid='11',chapter_idx=2,chapter_offset=30,percent=37,summary='synthetic summary'}
local target=assert(Readback.expected(id,position))
local bad_target=copy(target);bad_target.book_id='1234';requests={}
expect(not Progress.target(client,settings,access,bad_target,position.summary,current) and #requests==0,'numeric target accepted')
bad_target=copy(target);bad_target.chapter_uid='0'
expect(not Progress.target(client,settings,access,bad_target,position.summary,current) and #requests==0,'zero chapter accepted as a target')
local reached={book={bookId=id,chapterUid=11,chapterIdx=2,chapterOffset=30,progress=37,summary=position.summary,
    readingTime=0,recordReadingTime=0,ttsTime=0}}
web,native=copy(reached),copy(reached)
expect(Progress.target(client,settings,access,target,position.summary,current)~=nil,'exact dual target rejected')
for _,key in ipairs({'chapterUid','chapterIdx','chapterOffset','progress','summary','readingTime'}) do
    native=copy(reached);native.book[key]=key=='summary' and 'different' or 1
    expect(not Progress.target(client,settings,access,target,position.summary,current),'changed native '..key..' accepted')
end
native=copy(reached);web.book.summary='different'
expect(not Progress.target(client,settings,access,target,position.summary,current),'different Web summary accepted')
Access.capture,Access.matches_cb_initial_access,Native.capture,Auth.new=old_capture,old_matches,old_native,old_new
print(('cb_initial_progress_spec: %d checks'):format(checks))
