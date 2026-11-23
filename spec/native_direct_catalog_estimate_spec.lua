package.path='./?.lua;'..package.path
local Store=require('weread.lib.native_direct_catalog_store')
local digest=string.rep('a',64)
local catalog={book_id='42',version=7,reading_digest=digest,chapters={
    {chapterUid='11',wordCount=100,wordCountKnown=true},
    {chapterUid='12',wordCount=200,wordCountKnown=true},
    {chapterUid='13',wordCount=0,wordCountKnown=true},
    {chapterUid='14',wordCount=700,wordCountKnown=true},
}}
local entry={book_id='42',book_version=7,catalog_sha256=digest,catalog_order=2,catalog_count=4,
    chapter_uid='12',catalog_prev='11',catalog_next='13'}
local function near(value,expected) assert(value and math.abs(value-expected)<1e-9) end
local value=assert(Store.compact(catalog))
assert(Store.matches(value,entry))
near(Store.estimate(value,entry,0),10)
near(Store.estimate(value,entry,50),20)
near(Store.estimate(value,entry,100),30)
assert(not Store.estimate(value,entry,-1) and not Store.estimate(value,entry,0/0))
local function reject(change)
    local copy={};for k,v in pairs(entry) do copy[k]=v end;change(copy)
    assert(not Store.matches(value,copy) and not Store.estimate(value,copy,50))
end
reject(function(e) e.book_id='43' end)
reject(function(e) e.book_version=8 end)
reject(function(e) e.catalog_sha256=string.rep('b',64) end)
reject(function(e) e.catalog_count=3 end)
reject(function(e) e.catalog_order=1 end)
reject(function(e) e.catalog_prev='14' end)
reject(function(e) e.catalog_next='14' end)
local zero={};for k,v in pairs(entry) do zero[k]=v end
zero.chapter_uid='13';zero.catalog_order=3;zero.catalog_prev='12';zero.catalog_next='14'
assert(Store.matches(value,zero) and not Store.estimate(value,zero,50),'zero-weight current chapter was estimated')
catalog.chapters[2].wordCountKnown=false;assert(not Store.compact(catalog))
catalog.chapters[2].wordCountKnown=true;catalog.chapters[2].wordCount=-1;assert(not Store.compact(catalog))
catalog.chapters[2].wordCount=200;catalog.chapters[2].chapterUid='11';assert(not Store.compact(catalog))
catalog.chapters[2].chapterUid='12';catalog.chapters.extra=true;assert(not Store.compact(catalog))
catalog.chapters.extra=nil
value.chapters[2].words='200';assert(not Store.estimate(value,entry,50))
print('PASS: account-bound native catalog estimates require complete matching chapter weights')
