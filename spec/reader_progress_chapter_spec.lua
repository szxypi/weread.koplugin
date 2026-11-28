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

local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
reset()
catalog[4]={chapterUid='4'};catalog[5]={chapterUid='5'}
local opf='<manifest><item id="chapter_2" href="text/chapter-001.xhtml"/>'
    ..'<item id="chapter_4" href="text/chapter-002.xhtml"/></manifest>'
    ..'<spine><itemref idref="chapter_2"/><itemref idref="chapter_4"/></spine>'
local identity=Identity.encode(book,{catalog[2],catalog[4]},Identity.capture(book),Crypto.sha256_hex('text'))
local proof={kind='combined',order={'chapter_2','chapter_4'},items={chapter_2=true,chapter_4=true},
    file_id=Identity.decode(identity).file_id,book_version=1,opf_hash=Crypto.sha256_hex(opf)}
local document={file='/combined.epub'}
local page_flow=0
local render_path='OEBPS/text/chapter-001.xhtml'
function document:getDocumentFileContent(path) return path==Identity.PATH and identity or opf end
function document:getCurrentPage() return 12 end
function document:getCurrentPos() return 240 end
function document:getPageCount() return 24 end
function document:getPageXPointer() return '/body/DocFragment[1]/body/p.0' end
function document:getNormalizedXPointer(value) return value end
function document:getHTMLFromXPointers() return '<DocFragment Source="'..render_path..'">' end
function document:getPageFlow() return page_flow end
host.ui={document=document,getCurrentPage=document.getCurrentPage,handleEvent=function() end}
host.getChapterInfoFromFile=function() return nil,nil,true,true,proof end
local at_end={book=baseline,book_id='1',file=document.file,index=4,current='4',previous='3',next='5',
    combined_file=proof.file_id,combined_opf=proof.opf_hash}
assert(select(2,Resolve.resolve(host,at_end,1))==catalog[5],'partial EPUB lost its immediate successor')
assert(not Resolve.resolve(host,at_end,-1),'a file-end check permitted backwards navigation')
catalog[5].chapterUid='6';assert(not Resolve.resolve(host,at_end,1),'changed successor was accepted')
catalog[5].chapterUid='5'
catalog[6]={chapterUid='5'};assert(not Resolve.resolve(host,at_end,1),'duplicate successor was accepted');catalog[6]=nil
catalog[2],catalog[4]=catalog[4],catalog[2]
assert(not Resolve.resolve(host,at_end,1),'reordered partial file agreed with the catalog')
catalog[2],catalog[4]=catalog[4],catalog[2]
page_flow=1;assert(not Resolve.resolve(host,at_end,1),'nonlinear footnote end advanced to a new chapter');page_flow=0
proof.book_version=2;assert(not Resolve.resolve(host,at_end,1),'a different EPUB edition was accepted');proof.book_version=1
local from_viewport={book=baseline,book_id='1',file=document.file,index=2,current='2',previous='1',next='3',
    combined_file=proof.file_id,combined_opf=proof.opf_hash,from_viewport=true}
assert(select(2,Resolve.resolve(host,from_viewport,1))==catalog[3],'partial EPUB skipped the missing next chapter')
assert(select(2,Resolve.resolve(host,from_viewport,-1))==catalog[1],'partial EPUB lost the previous chapter')
render_path='OEBPS/text/chapter-002.xhtml'
assert(not Resolve.resolve(host,from_viewport,1),'changed chapter fragment was accepted')
render_path='OEBPS/text/chapter-001.xhtml'
page_flow=1
assert(not Resolve.resolve(host,from_viewport,1),'a footnote was treated as a chapter')
page_flow=0
opf=opf..' changed'
assert(not Resolve.resolve(host,at_end,1),'the open document did not match the verified file')
assert(not Resolve.resolve(host,from_viewport,-1),'viewport check accepted a replaced EPUB manifest')
print('reader_progress_chapter_spec: independent catalog and mapping checks passed')
