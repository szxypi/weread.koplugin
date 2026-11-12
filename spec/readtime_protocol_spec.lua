package.path='./?.lua;'..package.path
local P=require('weread.lib.readtime_protocol')
local function fails(callback) assert(not pcall(callback)) end
assert(P.sign({'5ecdcfd7f','123','1700000000','fixture_中文_😀'})=='1c7559efd27f4b162851e86f057000466ba406d7005f14a0323f4027b48a792c')
assert(P.sign({'a','b','c',''})=='cc40c3dd32695af0481d8cfdd4409bc5870387c01aeacfbaaaa215b4c0636529')
assert(P.sign({'0','999','4102444800','device_id_123'})=='714b65712962735b3fce784d35460e7688cf34fc4684a029894b5673e6fb7502')
local credentials={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='mock-access',refreshToken='mock-refresh'}
local function rows() return {{start_time=1700002799,duration=2,time_zone='+08:00',book_version=7}} end
local function body(value)
    return P.batch(credentials,'900001',value or rows(),'5ecdcfd7f','fixture-config',1700007200,123,
        {timestamp=1700007200123,random=456,current_zone='+00:00'})
end
local value=body();local book=value.books[1]
assert(book.signature=='de30ed1ad8d1c42bed906eb950814124be85a326fa587a6ee620724ae5b30c07')
assert(value.signature=='e66ff5c23bb86ece21ca4bedc74c92424dc0cd20ec9eb541c22a6c610eec0cb0')
assert(book.isResendReadingInfo==1 and book.readingTime==2 and book.finish==false and #book.hours==2)
assert(book.hours[1].startOfHour==1699999200 and book.hours[1].readingTime==1)
assert(book.hours[2].startOfHour==1700002800 and book.hours[2].readingTime==1)
for _i,key in ipairs({'chapterUid','chapterIdx','chapterOffset','voiceType','novelTime'}) do assert(book[key]==nil) end
assert(value.recordCreateTimeZone==nil and book.recordCreateTimeZone=='+00:00')
local keys={bookId=true,bookVersion=true,appId=true,deviceId=true,installId=true,summary=true,progress=true,currentProgress=true,
    autoTime=true,isLecture=true,isResendReadingInfo=true,lectureTime=true,lectureTextTime=true,novalTime=true,ttsTime=true,
    finish=true,risk=true,readingTime=true,recordCreateTimeZone=true,timestamp=true,random=true,hours=true,signature=true}
local count=0;for key in pairs(book) do assert(keys[key]);count=count+1 end;assert(count==23)
for _i,change in ipairs({{duration=0},{duration=61},{duration=true},{start_time='1700000000'},{start_time=1700007200},
    {book_version=0},{book_version=true},{book_version=2147483648},{time_zone='+14:01'},{extra='unexpected'}}) do
    local r=rows();for k,v in pairs(change) do r[1][k]=v end;fails(function() body(r) end)
end
local r=rows();r[2]=rows()[1];fails(function() body(r) end)
r=rows();r[2]={start_time=1700002802,duration=1,time_zone='+08:00',book_version=8};fails(function() body(r) end)
r=rows();r[3]={start_time=1700002802,duration=1,time_zone='+08:00',book_version=7};fails(function() body(r) end)
fails(function() body({}) end)
fails(function() P.sign({}) end)
fails(function() P.guest_token({feature={guest_token=false}}) end)
local guest,source=P.guest_token({feature={}});assert(guest=='5ecdcfd7f' and source=='client_default')
for _i,zone in ipairs({'+00:00','-03:30','+14:00'}) do assert(P.zone(zone)==zone) end
for _i,zone in ipairs({'+15:00','+14:01','+08:60','08:00'}) do fails(function() P.zone(zone) end) end
local zones={UTC='+00:00',['Asia/Shanghai']='+08:00',['America/New_York']='-05:00',['Pacific/Apia']='+13:00'}
local expected=zones[os.getenv('TZ')]
for _i,stamp in ipairs({1704070800,1719792000}) do
    local zone=P.time_zone(stamp);P.zone(zone);if expected then assert(zone==expected) end
end
print('PASS readtime_protocol_spec')
