package.path='./?.lua;'..package.path
local Catalog=require('weread.lib.translation_generation_catalog')
local function expect_failure(fn,label) local ok=pcall(fn);assert(not ok,label) end
local function source()
    return {bookId='456',format='epub',version=7},{data={{bookId='456',updated={
        {chapterUid=0,title='Cover',wordCount=0,price=0},
        {chapterUid=7,title='Chapter One',wordCount=1500,price=0,translateVersion=0,hasTranslated=false},
        {chapterUid=8,title='Chapter Two',wordCount=2100,price=10,paid=1},
        {chapterUid=9,title='Chapter Three',wordCount=2000,price=10},
    }}}}
end
local info,raw=source()
local result=Catalog.catalog(raw,'456',info)
assert(result.version==7 and #result.chapters==4 and #result.digest==64)
assert(Catalog.chapter(result,7).free_or_owned and Catalog.chapter(result,8).free_or_owned)
expect_failure(function() Catalog.chapter(result,9) end,'paid chapter admitted without ownership')
expect_failure(function() Catalog.chapter(result,1) end,'absent chapter admitted')
assert(Catalog.membership({isPaying=true}).paying and not Catalog.membership({isPaying='0'}).paying)
expect_failure(function() Catalog.membership({isPaying='yes'}) end,'ambiguous membership accepted')
expect_failure(function() Catalog.membership({isPaying=true,errcode=1}) end,'error membership accepted')
expect_failure(function() Catalog.membership({isPaying=true,succ=false}) end,'rejected membership accepted')
local copy_info,copy_raw=source()
assert(Catalog.catalog(copy_raw,'456',copy_info).digest==result.digest,'equivalent catalogue changed digest')
for _,mutate in ipairs({function(v) v.data[1].updated[2].price=1 end,
    function(v) v.data[1].updated[2].wordCount=1400 end,
    function(v) v.data[1].updated[2].title='Changed' end,
    function(v) v.data[1].updated[3].translateVersion=1 end}) do
    local fresh_info,fresh=source();mutate(fresh)
    assert(Catalog.catalog(fresh,'456',fresh_info).digest~=result.digest,'changed catalogue retained digest')
end
local invalid={
    function(i) i.bookId='999' end,
    function(i) i.errcode=1 end,
    function(_,v) v.succ=false end,
    function(i) i.version=-1 end,
    function(i) i.format='pdf' end,
    function(_,v) v.data[1].book={format=false,version=7} end,
    function(_,v) v.data[2]=v.data[1] end,
    function(_,v) v.data[1].updated[3].chapterUid=7 end,
    function(_,v) v.data[1].updated[2].price=0/0 end,
    function(_,v) v.data[1].updated[2].paid=-1 end,
    function(_,v) v.data[1].updated[2].hasTranslated='maybe' end,
    function(_,v) v.data[1].updated[2].title='broken\0title' end,
    function(_,v) v.data[1].updated[2].wordCount=-1 end,
    function(_,v) v.data[1].updated[1]=nil end,
}
for _,mutate in ipairs(invalid) do
    local fresh_info,fresh=source();mutate(fresh_info,fresh)
    expect_failure(function() Catalog.catalog(fresh,'456',fresh_info) end,'invalid catalogue accepted')
end
local body=Catalog.catalog_body('456')
assert(body.bookIds[1]=='456' and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
expect_failure(function() Catalog.catalog_body('CB_1') end,'unsupported book id accepted')
print('PASS: native translation membership, catalogue and chapter admission')
