package.path='./?.lua;'..package.path
local Snapshot=require('weread.lib.native_position_snapshot')
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local settings,store=F.access();local selected=assert(Access.capture(settings,store))
local before={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='Complete synthetic original'}
local expected=F.clone(before);expected.source='web';expected.has_chapter_index=true;expected.has_chapter_offset=true
local candidate=F.clone(before);candidate.chapter_offset=13;candidate.summary='Raw\r\n　 source excerpt'
local input={candidate=candidate,expected_remote=expected,source={raw_sha256=string.rep('b',64),file_id=string.rep('a',64),book_version=7}}
local original=Auth.new
local info={bookId='41',version=0};local position=F.clone(before);local fail,reads=nil,0
Auth.new=function() return {cancel=function() end,read_shelf=function() reads=reads+1;return {books={{bookId='41'}},archive={}} end,
    _request=function(_self,stage,_url,body)
        expect(body==nil,'snapshot attempted a write');reads=reads+1
        if fail then error(fail,0) end
        if stage=='position_metadata' then return info end
        return {book={bookId=position.book_id,chapterUid=2,chapterIdx=position.chapter_idx,chapterOffset=position.chapter_offset,
            progress=position.raw_percent,summary=position.summary,readingTime=10,recordReadingTime=20,ttsTime=0}}
    end} end
local gate={valid=function() return true end}
local result=Snapshot.run({},settings,selected,input,gate)
expect(result.kind=='ready' and result.metadata.version==0 and result.metadata.before.summary==before.summary)
expect(result.metadata.source_sha256==input.source.raw_sha256 and reads==3,'bounded observations or source hash changed')
position.chapter_offset=99;expect(Snapshot.run({},settings,selected,input,gate).kind=='changed','new cloud position was silently overwritten')
position=F.clone(before);info={bookId='41'};expect(Snapshot.run({},settings,selected,input,gate).kind=='unavailable','missing API version was invented')
info={bookId='41',version=0,bookVersion=7};expect(Snapshot.run({},settings,selected,input,gate).kind=='unavailable','archive version replaced native zero')
info={bookId='41',version=0};fail='native_auth/position_metadata/http_401'
expect(Snapshot.run({},settings,selected,input,gate).kind=='login','actual read401 was not classified')
fail='native_auth/position_metadata/http_500';expect(Snapshot.run({},settings,selected,input,gate).kind=='unavailable','500 permitted renewal')
expected.source='gateway';expect(not Snapshot.matches_expected(before,expected),'gateway offset became TXT wire coordinates')
expected.source='web';expected.has_chapter_index=false;expect(not Snapshot.matches_expected(before,expected),'missing index became zero')
Auth.new=original
print(('native_position_snapshot_spec: %d checks'):format(checks))
