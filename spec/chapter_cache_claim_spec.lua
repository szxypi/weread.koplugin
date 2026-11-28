package.path='./?.lua;'..package.path
local files,reads={},0
package.preload['weread.lib.source_archive']=function() return {read=function(path,wanted)
    reads=reads+1
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
local combined=Claims.inspect(book,'/shared.epub')
assert(combined.kind=='combined')
assert(Claims.complete(combined,{{chapterUid='2'},{chapterUid='4'}}))
local actual={};function actual:getDocumentFileContent(path) return files['/shared.epub'][path] end
assert(Claims.document_complete(combined,actual,'123',{{chapterUid='2'},{chapterUid='4'}}),
    'matching open archive was not recognized')
reads=0
local action={}
local proof=assert(Claims.combined(book,'/shared.epub',action))
assert(Claims.inspect(book,'/shared.epub',action,true)==proof and reads==1,
    'the same operation reread a verified combined archive')
local old_opf=files['/shared.epub']['OEBPS/content.opf']
files['/shared.epub']['OEBPS/content.opf']='broken'
local next_action={}
assert(not Claims.combined(book,'/shared.epub',next_action) and reads==2,
    'a new operation accepted an old archive proof')
files['/shared.epub']['OEBPS/content.opf']=old_opf
assert(Claims.combined(book,'/shared.epub',next_action) and reads==3,
    'an unsuccessful combined check was cached')
assert(not Claims.complete(combined,{{chapterUid='4'},{chapterUid='2'}}),
    'reordered catalog was treated as the same book')
files['/shared.epub']['OEBPS/content.opf']=old_opf..'changed'
assert(not Claims.document_complete(combined,actual,'123',{{chapterUid='2'},{chapterUid='4'}}),
    'changed open manifest was accepted')
files['/shared.epub']['OEBPS/content.opf']=old_opf
assert(not Claims.document_complete({kind='combined',items=combined.items,opf_hash=combined.opf_hash},
    actual,'123',{{chapterUid='2'},{chapterUid='4'}}),'unsealed archive was trusted for progress')
assert(not Claims.complete(combined,{{chapterUid='2'},{chapterUid='3'},{chapterUid='4'}})
    and not Claims.complete(combined,{{chapterUid='2'},{chapterUid='2'}})
    and not Claims.complete(combined,nil),'partial or ambiguous catalog was treated as complete')
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
book.cached_chapters={ ['2']='/single.epub' }
files['/single.epub']={
    [Identity.PATH]=identity({{chapterUid='2'}}),
    ['OEBPS/content.opf']=opf(Protocol.reader_url('123','2'),'<itemref idref="chapter"/>'),
}
assert(Claims.usable(book,'/single.epub','2',{},true),'saved list did not verify a matching single chapter')
files['/single.epub']['OEBPS/content.opf']=opf(Protocol.reader_url('123','4'),'<itemref idref="chapter"/>')
assert(not Claims.usable(book,'/single.epub','2',{},true),'saved list trusted an unrelated single-chapter file')

local Context=require('weread.lib.reader_context')
local original_identifier=Context.identifier
local checked=0
Context.identifier=function(...)
    checked=checked+1
    return original_identifier(...)
end
local many={cached_chapters={}}
for i=1,1000 do many.cached_chapters[tostring(i)]='/cache/'..i..'.epub' end
many.cached_chapters[999]='/cache/999.epub'
local shared,mapped=Claims.shared(many,'/cache/999.epub')
assert(not shared and mapped and checked==2,'a file lookup checked unrelated chapter identifiers')
checked=0
local uid
uid,shared=Claims.mapped_chapter(many,'/cache/999.epub')
assert(uid=='999' and not shared and checked==2,'numeric alias changed the known chapter')
checked=0
shared,mapped=Claims.shared(many,'/missing.epub')
assert(not shared and not mapped and checked==0,'an absent path checked unrelated chapter identifiers')
many.cached_full_book='/cache/999.epub'
assert(Claims.shared(many,'/cache/999.epub'),'the full-book field made a single mapping ambiguous')
many.cached_full_book=nil
many.cached_chapters['1000']='/cache/999.epub'
uid,shared=Claims.mapped_chapter(many,'/cache/999.epub')
assert(not uid and shared,'multiple chapters sharing one path were treated as one chapter')

checked=0
local lookup={}
assert(Claims.shared(many,'/cache/999.epub',lookup))
assert(not Claims.shared(many,'/cache/1.epub',lookup) and checked==1001,
    'the index for multiple paths was not reused')
Context.identifier=original_identifier
print('chapter_cache_claim_spec: shared single, combined and unknown EPUB identities passed')
