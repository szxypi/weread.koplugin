package.path='./?.lua;'..package.path
local files={}
package.preload['weread.lib.source_archive']=function() return {read=function(path,wanted)
    local source=files[path];if not source then return nil end
    local out={}
    for key in pairs(wanted) do if not source[key] then return nil end;out[key]=source[key] end
    return out
end} end
local Crypto=require('weread.lib.crypto')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local Claims=require('weread.lib.chapter_cache_claim')
local book={book_id='123',bookVersion=5,cached_chapters={['2']='/shared.epub',['4']='/shared.epub'}}
local function identity(chapters)
    return Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex('text'))
end
local function opf(source,spine)
    return '<metadata><dc:source>'..source..'</dc:source></metadata><spine>'..spine..'</spine>'
end
files['/shared.epub']={
    [Identity.PATH]=identity({{chapterUid='4'}}),
    ['OEBPS/content.opf']=opf(Protocol.reader_url('123','4'),'<itemref idref="chapter"/>')}
assert(Claims.shared(book,'/shared.epub'))
local result=Claims.inspect(book,'/shared.epub')
assert(result.kind=='single' and result.uid=='4')
assert(not Claims.usable(book,'/shared.epub','2') and Claims.usable(book,'/shared.epub','4'))
files['/shared.epub']={[Identity.PATH]=identity({{chapterUid='2'},{chapterUid='4'}}),
    ['OEBPS/content.opf']=opf(Protocol.reader_url('123'),'<itemref idref="chapter_2"/><itemref idref="chapter_4"/>')}
assert(Claims.inspect(book,'/shared.epub').kind=='combined')
assert(Claims.usable(book,'/shared.epub','2') and Claims.usable(book,'/shared.epub','4')
    and not Claims.usable(book,'/shared.epub','3'))
files['/shared.epub']['OEBPS/content.opf']=opf(Protocol.reader_url('123'),
    '<itemref idref="cover"/><itemref idref="chapter_2"/><itemref idref="chapter_4"/>')
assert(Claims.inspect(book,'/shared.epub').kind=='combined','cover broke chapter count')
files['/shared.epub'][Identity.PATH]=nil
assert(Claims.inspect(book,'/shared.epub').kind=='combined','legacy combined EPUB lost access')
files['/shared.epub'][Identity.PATH]='corrupt'
assert(Claims.inspect(book,'/shared.epub').kind=='unknown','corrupt identity accepted')
files['/shared.epub'][Identity.PATH]=identity({{chapterUid='2'}})
assert(Claims.inspect(book,'/shared.epub').kind=='unknown','identity chapter count mismatch accepted')
files['/shared.epub']['OEBPS/content.opf']=opf(Protocol.reader_url('456'),'<itemref idref="chapter_2"/>')
assert(Claims.inspect(book,'/shared.epub').kind=='unknown','foreign book accepted')
book.cached_chapters={['2']='/shared.epub',[2]='/shared.epub'}
assert(not Claims.shared(book,'/shared.epub') and Claims.usable(book,'/shared.epub','2'),'numeric alias treated as another chapter')
book.cached_full_book='/shared.epub'
assert(Claims.shared(book,'/shared.epub') and not Claims.usable(book,'/shared.epub','2'),'full-file collision not checked')
print('chapter_cache_claim_spec: shared single, combined and unknown EPUB identities passed')
