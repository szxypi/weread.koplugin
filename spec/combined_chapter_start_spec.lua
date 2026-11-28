package.path='./?.lua;'..package.path
local Dom=require('weread.lib.source_dom')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local book={book_id='123',bookVersion=7}
local function make()
    local opf='<package><metadata><dc:source>'..Protocol.reader_url('123')..'</dc:source></metadata>'
        ..'<manifest><item id="cover" href="text/cover.xhtml"/><item id="chapter_2" href="text/chapter-001.xhtml"/>'
        ..'<item id="chapter_4" href="text/chapter-002.xhtml"/></manifest>'
        ..'<spine><itemref idref="cover"/><itemref idref="chapter_2"/><itemref idref="chapter_4"/></spine></package>'
    local doc={opf=opf,render='OEBPS/text/chapter-002.xhtml'}
    local identity=Identity.encode(book,{{chapterUid=2},{chapterUid=4}},Identity.capture(book),Crypto.sha256_hex('source'))
    function doc:getDocumentFileContent(path)
        if path=='OEBPS/content.opf' then return self.opf elseif path==Identity.PATH then return identity end
    end
    function doc:getNormalizedXPointer(point)
        return point:gsub('%.0$','/body/p/text().0')
    end
    function doc:getHTMLFromXPointers() return '<DocFragment Source="'..self.render..'"></DocFragment>' end
    function doc:getNextVisibleChar() return '/body/DocFragment[3]/body/p/text().1' end
    return doc
end
local doc=make()
assert(Dom.chapter_start(doc,'123','4')=='/body/DocFragment[3]/body/p/text().1','wrong spine ordinal')
local proof={opf_hash=Crypto.sha256_hex(doc.opf),file_id=Identity.read_document(doc,'123').file_id}
assert(Dom.chapter_start(doc,'123','4',proof),'matching archive proof was rejected')
proof.opf_hash=string.rep('0',64);assert(not Dom.chapter_start(doc,'123','4',proof),'changed manifest accepted')
proof.opf_hash=Crypto.sha256_hex(doc.opf);proof.file_id=string.rep('0',64)
assert(not Dom.chapter_start(doc,'123','4',proof),'replaced book identity accepted')
doc=make();doc.render='OEBPS/text/chapter-001.xhtml';assert(not Dom.chapter_start(doc,'123','4'),'wrong rendered member accepted')
doc=make();doc.opf=doc.opf:gsub('chapter_4','chapter_2');assert(not Dom.chapter_start(doc,'123','4'),'missing target accepted')
doc=make();doc.opf=doc.opf:gsub(Protocol.reader_url('123'),Protocol.reader_url('456'),1)
assert(not Dom.chapter_start(doc,'123','4'),'foreign source accepted')
doc=make();doc.opf=doc.opf:gsub('</manifest>','<item id="chapter_4" href="text/chapter-003.xhtml"/></manifest>')
assert(not Dom.chapter_start(doc,'123','4'),'duplicate target accepted')
doc=make();doc.opf=doc.opf:gsub('text/chapter%-002.xhtml','../foreign.xhtml')
assert(not Dom.chapter_start(doc,'123','4'),'unsafe member accepted')
doc=make();assert(not Dom.chapter_start(doc,'123',9007199254740992),'inexact chapter accepted')
print('combined_chapter_start_spec: source, spine, cover and rendered-member checks passed')
