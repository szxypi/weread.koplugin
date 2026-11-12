package.path='./?.lua;'..package.path
local P=require('weread.lib.native_position_protocol');local C=require('weread.lib.native_position_contract')
local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(value) checks=checks+1;assert(value) end
local function fails(callback) expect(not pcall(callback)) end
local credentials={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh'}
local point={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic full summary'}
local function body(p,version,chapter_progress)
    return P.body(credentials,p or point,version or 0,'5ecdcfd7f',1700000000,123,'+08:00',chapter_progress,{})
end
local value=body()
expect(value.signature=='6a97d1c459c91c2bfb68769d0fa1e7ba72ac128faa3574aa76ce31686baf64a2')
expect(value.summary==point.summary and value.chapterUid==2 and value.chapterOffset==12 and value.bookVersion==0)
expect(value.readingTime==0 and value.ttsTime==0 and next(value.hours)==nil)
expect(value.isResendReadingInfo==nil and value.voiceType==nil and value.chapterProgress==nil)
expect(body(point,0,12.5).chapterProgress==12.5)
local long=F.clone(point);long.summary=string.rep('合成',100)..'\r\n😀';expect(body(long).summary==long.summary)
for _i,change in ipairs({{chapter_uid='9007199254740992'},{chapter_uid='0'},{chapter_idx=true},{chapter_offset=-1},{raw_percent=0/0},
    {summary='bad\0'},{summary='\237\160\128'},{summary=string.rep('😀',513)},{summary=string.rep('a',513)}}) do
    local p=F.clone(point);for key,v in pairs(change) do p[key]=v end;fails(function() body(p) end)
end
fails(function() body(point,true) end);fails(function() body(point,0,0/0) end)
local invalid=F.clone(credentials);invalid.accessToken='bad\nsecret';fails(function() P.body(invalid,point,0,'guest',1700000000,1,'+08:00',nil,{}) end)
for _i,ack in ipairs({{succ=1},{succ=true},{succ=1,errcode=0}}) do expect(P.confirmed(ack)) end
for _i,ack in ipairs({{},{succ='1'},{succ=1,errCode=false},{succ=1,errcode=-1},{status=200}}) do expect(not P.confirmed(ack)) end
local raw={book={bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=12,progress=17,summary=point.summary,readingTime=10,recordReadingTime=20,ttsTime=0}}
local snapshot=P.snapshot(raw,'41');expect(P.equal(snapshot.position,point));expect(snapshot.counts.recordReadingTime==20)
for _i,key in ipairs({'chapterIdx','chapterOffset','summary','readingTime'}) do
    local changed=F.clone(raw);changed.book[key]=nil;fails(function() P.snapshot(changed,'41') end)
end
local ambiguous={first=raw.book,second=F.clone(raw.book)};fails(function() P.snapshot(ambiguous,'41') end)
local wrong=F.clone(raw);wrong.book.bookId='42';fails(function() P.snapshot(wrong,'41') end)
local after=F.clone(point);after.chapter_offset=13
local metadata={book_id='41',before=point,desired=after,counts=snapshot.counts,version=0,shelf_sha256=string.rep('a',64),
    source_sha256=string.rep('b',64),file_id='synthetic-file',basis='raw_txt_utf16'}
expect(C.valid(metadata));expect(C.same(metadata,F.clone(metadata)))
for _i,key in ipairs({'source_sha256','shelf_sha256','file_id','version'}) do
    local changed=F.clone(metadata);changed[key]=key=='version' and 1 or key=='file_id' and 'other-file' or string.rep('c',64)
    expect(not C.same(metadata,changed))
end
local changed=F.clone(metadata);changed.desired.summary='different';expect(not C.same(metadata,changed))
for _i,mutate in ipairs({function(p) p.basis='filtered_xhtml_utf16' end,function(p) p.before=nil end,function(p) p.counts.extra=0 end,
    function(p) p.desired.extra=true end,function(p) p.version=true end}) do local p=F.clone(metadata);mutate(p);expect(not C.valid(p)) end
print('PASS native_position_protocol_spec '..checks)
