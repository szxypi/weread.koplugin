package.path='./?.lua;'..package.path
local Progress=require('weread.lib.remote_progress')
local Mapper=require('weread.lib.position_mapper')
local checks=0
local function equal(a,b) checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function reject(data,reason)
    local value,why=Progress.project(data,'book','web');equal(value,nil);equal(why,reason or 'progress_invalid')
end
local valid={book={bookId='book',progress=25.4,chapterUid=22,chapterIdx=2,chapterOffset=150,summary='valid'}}
local result=assert(Progress.project(valid,'book','web'))
equal(result.book_id,'book');equal(result.percent,25.4);equal(result.chapter_uid,22)
equal(result.has_chapter_offset,true);equal(result.updated_at,0)
reject({bookId='other',data=valid},'progress_book_mismatch')
reject({bookId='book',book_id='other',data=valid},'progress_book_mismatch')
reject({book={bookId='other',progress=25}},'progress_book_mismatch')
reject({data={valid,valid}},'progress_ambiguous')
reject({errCode=-1,book=valid.book},'progress_rejected')
reject({succ=false,book=valid.book},'progress_rejected')
reject({recordReadingTime=120},'progress_not_found')
for _i,percent in ipairs({-1,101,math.huge,-math.huge,0/0,'NaN','inf','bad',true,'0x10','1_0','١'}) do reject({book={progress=percent}}) end
equal(assert(Progress.project({progress=' 2.54e1 '},'book','web')).percent,25.4)
for _i,key in ipairs({'chapterOffset','chapterIdx','updateTime'}) do
    for _j,value in ipairs({-1,0.5,math.huge,0/0,'bad',true,{}}) do reject({book={progress=25,[key]=value}}) end
end
reject({book={progress=25,chapterOffset=2147483648}})
reject({book={progress=25,chapterUid={}}})
reject({book={progress=25,chapterUid=''}})
reject({book={progress=25,chapterUid=22,chapterId=33}})
reject({book={progress=25,readingProgress=26}})
reject({book={progress=25,chapterOffset=10,offset=11}})
reject({book={progress=25,summary={}}})
reject({book={progress=25,summary=string.rep('x',16385)}})
reject({book={progress=25,summary='nul\0text'}})
local cyclic={};cyclic.data=cyclic;reject(cyclic)
local large={};for index=1,513 do large[index]={} end;reject(large)
local legacy=assert(Progress.project({data={book_id='book',readingProgress='25.4',chapterId='22',chapterIndex='2',
    chapterPos='150',update_time='123',chapterTitle='legacy'}},'book','gateway'))
equal(legacy.percent,25.4);equal(legacy.chapter_uid,'22');equal(legacy.chapter_idx,2)
equal(legacy.updated_at,123);equal(legacy.summary,'legacy')
result=assert(Progress.project({data={{bookId='other',progress=90},valid}},'book','web'))
equal(result.percent,25.4)
result=assert(Progress.project({book={progress=0,chapterUid=0,chapterOffset=0}},'book','web'))
equal(result.chapter_uid,0);equal(result.has_chapter_offset,true)
result=assert(Progress.project({book={progress=100}},'book','web'));equal(result.percent,100)
equal(result.has_chapter_offset,false)
local mapped=assert(Mapper.normalize_remote(valid,'book','web',{{chapterUid=22,chapterIdx=2,wordCount=300}}))
equal(mapped.percent,50);equal(mapped.raw_percent,25.4);equal(mapped.position_basis,'chapter_offset')
print('remote_progress_spec: '..checks..' checks')
