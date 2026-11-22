package.path='./?.lua;'..package.path
local Catalog=require('weread.lib.native_book_catalog')
local Reference=require('weread.lib.translation_generation_catalog')
local function fixture()
    return {bookId='456',format='epub',version=7},{data={{bookId='456',updated={
        {chapterUid=0,title='Cover',wordCount=0,price=0},
        {chapterUid=7,title='First',chapterIdx=1,level=1,wordCount=1500,price=0},
        {chapterUid='8',title='Second',chapterIndex='2',level=2,wordCount=2100,price=10,paid=1},
        {chapterUid=9,title='Third',wordCount=500,price=10},
    }}}}
end
local info,raw=fixture()
local value=Catalog.project(raw,'456',info)
assert(value.digest==Reference.catalog(raw,'456',info).digest and #value.chapters==4)
assert(type(value.reading_digest)=='string' and #value.reading_digest==64)
assert(#value.reading_chapters==3 and value.reading_chapters[1].chapterUid=='7'
    and value.reading_chapters[1].chapterIdx==1 and value.reading_chapters[1].downloadable
    and value.reading_chapters[2].chapterIdx==2 and value.reading_chapters[2].downloadable
    and value.reading_chapters[3].chapterIdx==nil and not value.reading_chapters[3].downloadable)
assert(raw.data[1].updated[3].chapterUid=='8','source catalog was modified')
local changed_info,changed_raw=fixture();changed_raw.data[1].updated[2].chapterIdx=0
local changed=Catalog.project(changed_raw,'456',changed_info)
assert(changed.digest==value.digest and changed.reading_digest~=value.reading_digest,
    'reading catalog digest omitted chapter index')
changed_raw.data[1].updated[2].chapterIdx=nil
assert(Catalog.project(changed_raw,'456',changed_info).reading_digest~=changed.reading_digest,
    'reading catalog digest confused zero and missing chapter index')
changed_raw.data[1].updated[2].chapterIdx=1;changed_raw.data[1].updated[2].level=2
assert(Catalog.project(changed_raw,'456',changed_info).reading_digest~=value.reading_digest,
    'reading catalog digest omitted hierarchy level')
local invalid={
    function(row) row.chapterIdx=-1 end,
    function(row) row.chapterIdx='01' end,
    function(row) row.chapterIndex=2 end,
    function(row) row.level=true end,
    function(row) row.wordCount=100000001 end,
    function(row) row.title=string.rep('x',2049) end,
    function(row) row.title='invalid'..string.char(255) end,
}
for _,mutate in ipairs(invalid) do
    local i,r=fixture();mutate(r.data[1].updated[2])
    local projected=Catalog.project(r,'456',i)
    assert(not projected.reading_chapters and projected.chapters[2].uid==7,
        'invalid display fields either exposed a reading catalog or blocked entitlement')
end
local calls={}
local auth={_request=function(_self,stage,url,body,credentials)
    calls[#calls+1]=stage;assert(credentials==true)
    if stage=='chapter_info' then
        assert(url=='https://i.weread.qq.com/book/info?bookId=456' and body==nil);return info
    end
    assert(stage=='chapter_catalog' and url=='https://i.weread.qq.com/book/chapterInfos'
        and body.bookIds[1]=='456' and body.synckeys[1]==0);return raw
end}
assert(Catalog.read(auth,true,'456','chapter').digest==value.digest and #calls==2)
assert(not pcall(Catalog.read,auth,true,'456','invalid'))
assert(not pcall(Catalog.read,auth,true,'456/other','chapter') and #calls==2,
    'invalid book identity sent a metadata request')
print('PASS: native book catalog preserves order, entitlement and display boundaries')
