-- Re-read chapter data; never navigate using a stale hydrated book table.
package.path='./?.lua;'..package.path
local catalog,book
package.preload['weread.lib.content']=function() return {load_catalog_cache=function(_,_,target)
    target.chapters=catalog;return catalog
end} end
local Resolve=require('weread.lib.reader_progress_chapter')
local baseline={book_id='1',bookVersion=1,cache_dir='/cache/1',cached_chapters={['2']='/2.epub'}}
local expected={book=baseline,book_id='1',file='/2.epub',index=2,current='2',previous='1',next='3'}
local host={settings={get_book=function() return book end},library_db={},
    getChapterInfoFromFile=function(_,entry,file)
        for i,row in ipairs(entry.chapters) do if entry.cached_chapters[tostring(row.chapterUid)]==file then return i,row,false end end
    end}
local function reset()
    catalog={{chapterUid='1'},{chapterUid='2'},{chapterUid='3'}}
    book={book_id='1',bookVersion=1,cache_dir='/cache/1',cached_chapters={['2']='/2.epub'}}
end
reset();local fresh,target=Resolve.resolve(host,expected,-1)
assert(fresh==book and fresh~=baseline and target==catalog[1])
assert(select(2,Resolve.resolve(host,expected,1))==catalog[3])
book.bookVersion=2;assert(not Resolve.resolve(host,expected,1));reset()
book.cached_chapters['2']='/different.epub';assert(not Resolve.resolve(host,expected,1));reset()
catalog[3].chapterUid='4';assert(not Resolve.resolve(host,expected,1));reset()
catalog[1],catalog[2]=catalog[2],catalog[1];assert(not Resolve.resolve(host,expected,1));reset()
catalog[3].chapterUid='2';expected.next='2';assert(not Resolve.resolve(host,expected,1));expected.next='3';reset()
catalog[4]={chapterUid='3'};assert(not Resolve.resolve(host,expected,1),'ambiguous target chapter accepted');reset()
catalog[3].chapterUid=9007199254740992;assert(not Resolve.resolve(host,expected,1),'inexact numeric chapter accepted');reset()
local cached=catalog;catalog=nil;host.library_db.getChapters=function() return cached end
assert(select(2,Resolve.resolve(host,expected,1))==cached[3])
assert(not Resolve.resolve(host,{book=baseline,book_id='1'},1) and not Resolve.resolve(host,expected,0))
print('reader_progress_chapter_spec: independent catalog and mapping checks passed')
