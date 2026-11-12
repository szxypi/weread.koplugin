package.path='./?.lua;'..package.path
local State=require('weread.lib.native_cloud_state')
local P=require('weread.lib.native_position_protocol')
local C=require('weread.lib.native_position_contract')
local O=require('weread.lib.native_position_observation')
local Hash=require('weread.lib.thought_edit_contract')
local F=require('spec.helpers.thought_edit_fixture')
local n=0;local function expect(value) n=n+1;assert(value,'check '..n) end
local raw={book={bookId='41',chapterUid=0,chapterOffset=0,progress=0,readingTime=0,recordReadingTime=0,ttsTime=0}}
local absent=assert(State.from(raw,'41'));expect(State.none(absent) and absent.chapter_idx==nil and absent.summary==nil)
local present=F.clone(raw);present.book.chapterIdx=0;present.book.summary=''
present=assert(State.from(present,'41'));expect(State.none(present) and not State.equal(absent,present))
expect(not pcall(P.point,absent) and not P.equal(absent,absent))
for _i,change in ipairs({{chapterUid=false},{chapterOffset=false},{chapterOffset=1},{progress=1},{chapterIdx=1},{summary='text'},{bookId='42'}}) do
    local v=F.clone(raw);for k,x in pairs(change) do v.book[k]=x==false and nil or x end;expect(not State.from(v,'41'))
end
for _i,change in ipairs({{index_present=true},{summary_present=true},{summary=false},{kind='point'},{book_id='book'},{chapter_uid='1'},{extra=1}}) do
    local v=F.clone(absent);for k,x in pairs(change) do v[k]=x end;expect(not State.valid(v))
end
expect(State.snapshot(raw,'41').counts.readingTime==0)
local point={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic complete summary'}
local metadata={book_id='41',before=F.clone(point),desired=F.clone(point),counts={readingTime=0,recordReadingTime=0,ttsTime=0},version=0,
    shelf_sha256=string.rep('a',64),source_sha256=string.rep('b',64),file_id='file',basis='raw_txt_utf16'}
expect(C.valid(metadata))
local old_hash=Hash.digest({'native-position-binding-v1','41','raw_txt_utf16','file',metadata.source_sha256,metadata.shelf_sha256,
    0,P.point_hash(point),P.point_hash(point),0,0,0})
expect(C.hash(metadata)==old_hash)
local observation={point=point,counts=metadata.counts,version=0,shelf_sha256=metadata.shelf_sha256}
expect(O.hash(observation)==Hash.digest({'native-position-observation-v1',P.point_hash(point),0,metadata.shelf_sha256,0,0,0}))
metadata.before=absent;expect(C.valid(metadata) and C.hash(metadata)~=old_hash)
metadata.counts.readingTime=1;expect(not C.valid(metadata))
observation.point=absent;expect(O.valid(observation),'read-only no-chapter state may have nonzero counters')
metadata.counts.readingTime=0;metadata.desired=absent;expect(not C.valid(metadata),'absence became a restoration target')
print('native_cloud_state_spec: '..n..' checks')
