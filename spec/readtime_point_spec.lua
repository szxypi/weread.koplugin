package.path='./?.lua;'..package.path
local F=require('spec.helpers.thought_edit_fixture')
local Point=require('weread.lib.readtime_point')
local n=0;local function expect(v) n=n+1;assert(v,'check '..n) end
local function raw() return {book={bookId='42',chapterUid=7,chapterIdx=0,chapterOffset=120,progress=10,readingTime=2,recordReadingTime=0,ttsTime=0}} end
for _i,kind in ipairs({'native','web'}) do
    local value=raw();local absent=Point.hash(value,'42',kind)
    expect(Point.project(value,'42',kind).summary.present==false)
    value.book.summary='';local empty=Point.hash(value,'42',kind);expect(empty~=absent)
    value.book.summary='Full summary\r\n😀';local text=Point.hash(value,'42',kind);expect(text~=empty and text~=absent)
    value.book.chapterTitle='Title';expect(Point.hash(value,'42',kind)~=text)
    for _j,key in ipairs({'chapterIdx','chapterUid','chapterOffset','progress'}) do
        local missing=raw();missing.book[key]=nil;expect(not pcall(Point.hash,missing,'42',kind))
    end
    for _j,bad in ipairs({false,4,{}}) do value=raw();value.book.summary=bad;expect(not pcall(Point.hash,value,'42',kind)) end
    value=raw();value.book.summary=string.rep('x',16385);expect(not pcall(Point.hash,value,'42',kind))
    value=raw();value.book.summary='unsafe\0';expect(not pcall(Point.hash,value,'42',kind))
    value=raw();value.book.chapter_uid=8;expect(not pcall(Point.hash,value,'42',kind))
    value=raw();value.book.readingTime=3;expect(Point.hash(value,'42',kind)==absent)
    expect(not pcall(Point.hash,raw(),'43',kind))
end
expect(type(F.clone)=='function')
print('readtime_point_spec: '..n..' checks')
