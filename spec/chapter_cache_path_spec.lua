package.path='./?.lua;'..package.path
local files,archives={},{}
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function(path) return files[path] end} end
package.preload['weread.lib.source_archive']=function() return {read=function(path) return archives[path] end} end
local Crypto=require('weread.lib.crypto')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local Paths=require('weread.lib.chapter_cache_path')
local book={book_id='123',bookVersion=7,cached_chapters={}}
local first={chapterUid='2',title='重名'}
local second={chapterUid='4',title='重名'}
local function put(path,owner,uid,ino)
    files[path]={mode='file',dev=1,ino=ino or 1,size=100,modification=2}
    archives[path]={[Identity.PATH]=Identity.encode(owner,{{chapterUid=uid}},Identity.capture(owner),Crypto.sha256_hex('text')),
        ['OEBPS/content.opf']='<package><dc:source>'..Protocol.reader_url(owner.book_id,uid)..'</dc:source></package>'}
end
local a=Paths.plan(book,first,'/books/123')
local b=Paths.plan(book,second,'/books/123')
assert(a.path~=b.path and #a.path<128 and Paths.current(a),'duplicate titles share a destination')
put(a.path,book,'2');assert(not Paths.current(a),'new destination appeared during packaging')
book.cached_chapters['2']=a.path
local repeat_a=Paths.plan(book,first,'/books/123')
assert(repeat_a.path==a.path and Paths.current(repeat_a),'verified chapter lost its existing path')
local opf=archives[a.path]['OEBPS/content.opf'];archives[a.path]['OEBPS/content.opf']='<dc:source>foreign</dc:source>'
assert(not Paths.current(repeat_a),'changed chapter identity was accepted with unchanged file metadata')
archives[a.path]['OEBPS/content.opf']=opf
files[a.path]={mode='file',dev=1,ino=99,size=100,modification=2}
assert(not Paths.current(repeat_a),'replacement file was accepted')
put(a.path,book,'2')
local legacy='/books/123/旧章节.epub';put(legacy,book,'2',3);book.cached_chapters['2']=legacy
assert(Paths.plan(book,first,'/books/123').path==legacy,'verified legacy path was not preserved')
book.cached_chapters['4']=legacy
local shared=Paths.plan(book,first,'/books/123')
assert(shared.path~=legacy,'shared legacy file was overwritten')
book.cached_chapters['4']=nil;archives[legacy]['OEBPS/content.opf']='<dc:source>foreign</dc:source>'
assert(Paths.plan(book,first,'/books/123').path~=legacy,'foreign legacy file was overwritten')
book.cached_chapters['2']='/other/legacy.epub';put('/other/legacy.epub',book,'2')
assert(Paths.plan(book,first,'/books/123').path~='/other/legacy.epub','outside legacy file was reused')
local foreign={book_id='456',bookVersion=7};put(b.path,foreign,'4');book.cached_chapters['4']=nil
local safe=Paths.plan(book,second,'/books/123')
assert(safe.path~=b.path and Paths.current(safe),'occupied destination was overwritten')
files[safe.path]={mode='directory'};assert(not Paths.current(safe),'directory appeared after planning')
assert(not pcall(Paths.plan,book,{chapterUid='2',chapterId='4'},'/books/123'),'conflicting identifiers accepted')
assert(not pcall(Paths.plan,book,{chapterUid=9007199254740992},'/books/123'),'imprecise chapter identifier accepted')
assert(not pcall(Paths.plan,book,{title='missing'},'/books/123'),'missing chapter identifier accepted')
print('chapter_cache_path_spec: unique chapters, verified legacy reuse and publication guards passed')
