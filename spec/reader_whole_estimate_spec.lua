package.path='./?.lua;'..package.path
local metadata
package.preload['weread.lib.position_source']=function() return {
    document_metadata=function(_,book,uid)
        if book=='book' and uid=='2' then return metadata end
    end,
} end
package.preload['weread.lib.book_file_identity']=function() return {version=function(value) return tonumber(value) or 0 end} end
local M=require('weread.lib.reader_whole_estimate')
local catalog={{chapterUid='1',wordCount=100},{chapterUid='2',wordCount='200'},
    {chapterUid='3',wordCount=700}}
local function near(actual,expected) assert(actual and math.abs(actual-expected)<1e-9) end
near(M.estimate(catalog,2,'2',0),10)
near(M.estimate(catalog,2,'2',50),20)
near(M.estimate(catalog,2,'2',100),30)
near(M.estimate(catalog,1,'1',0),0)
near(M.estimate(catalog,3,'3',100),100)
assert(not M.estimate(catalog,2,'3',50))
assert(not M.estimate(catalog,2,'2',-1) and not M.estimate(catalog,2,'2',0/0))
for _,bad in ipairs({0,-1,1.5,math.huge,true,'no'}) do
    local old=catalog[2].wordCount;catalog[2].wordCount=bad
    assert(not M.estimate(catalog,2,'2',50));catalog[2].wordCount=old
end
catalog[3].chapterUid='2';assert(not M.estimate(catalog,2,'2',50));catalog[3].chapterUid='3'
catalog.extra={};assert(not M.estimate(catalog,2,'2',50));catalog.extra=nil
local missing=catalog[2];catalog[2]=nil;assert(not M.estimate(catalog,1,'1',50));catalog[2]=missing
local book={book_id='book',bookVersion=7}
metadata={identity={chapter_count=1,book_version=7}}
near(M.for_document({},book,catalog,2,'2',50),20)
metadata.identity.book_version=8;assert(not M.for_document({},book,catalog,2,'2',50))
metadata.identity.book_version=0;near(M.for_document({},book,catalog,2,'2',50),20)
metadata.identity.chapter_count=2;assert(not M.for_document({},book,catalog,2,'2',50))
metadata=nil;assert(not M.for_document({},book,catalog,2,'2',50))
print('reader_whole_estimate_spec: weighted scope, malformed catalogs and file binding passed')
