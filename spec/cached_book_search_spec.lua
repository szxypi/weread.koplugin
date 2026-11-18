package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(value)
    return value:gsub('&amp;','&'):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&quot;','"')
end} end
local Search=require('weread.lib.cached_book_search')
local Target=require('weread.lib.cached_search_target')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,label) checks=checks+1;if not value then error(label) end end
local function fixture(book,uid,raw)
    local b={book_id=book,bookVersion=7};local chapter={chapterUid=uid}
    local capture=assert(Source.capture(b,chapter,raw,'web_xhtml'))
    local root=Identity.encode(b,{chapter},Identity.capture(b),Crypto.sha256_hex(raw))
    local identity=assert(Identity.decode(root));local render='OEBPS/text/chapter.xhtml'
    local metadata=assert(Source.bind(capture,identity,render,Crypto.sha256_hex(raw)))
    local members={[Identity.PATH]=root,[Source.meta_path(uid)]=metadata,[Source.path_meta_path(render)]=metadata,
        [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[render]=raw}
    return members
end
local paragraphs={}
for i=1,37 do paragraphs[#paragraphs+1]=string.format('<p>distinct context %03d needle distinct trailing %03d</p>',i,i) end
local raw='<html><body>'..table.concat(paragraphs)..'</body></html>'
local files={['/cached.epub']=fixture('CB_Synthetic','2',raw)}
local function archive(file,wanted)
    local items=files[file];if not items then return nil end
    local out={};for name,limit in pairs(wanted) do
        if not items[name] or #items[name]>limit then return nil end
        out[name]=items[name]
    end
    return out
end
local input={book='CB_Synthetic',chapter='2',paths={'/missing.epub','/cached.epub'},keyword='needle',from=1}
local first=Search.scan(input,archive)
expect(type(first.hits)=='table' and #first.hits==30 and type(first.next_byte)=='number' and not first.complete,
    'first batch did not retain a continuation')
input.from=first.next_byte;local second=Search.scan(input,archive)
expect(#second.hits==7 and second.complete and second.unresolved==0,'continuation lost or repeated hits')
expect(first.hits[1].offset~=second.hits[1].offset,'continuation repeated the first hit')
local folded_input={book=input.book,chapter=input.chapter,paths={'/cached.epub'},keyword='NEeDLE',from=1,
    ignore_ascii_case=true}
local folded=Search.scan(folded_input,archive)
expect(#folded.hits==30 and folded.hits[1].offset==first.hits[1].offset
    and folded.hits[1].context:find('needle',1,true),'folded search lost the original location or context')
folded_input.from=folded.next_byte;local folded_next=Search.scan(folded_input,archive)
expect(#folded_next.hits==7 and folded_next.complete and folded_next.hits[1].offset==second.hits[1].offset,
    'folded continuation lost or repeated matches')
folded_input.from=1;folded_input.ignore_ascii_case=false
expect(#Search.scan(folded_input,archive).hits==0,'case-sensitive search ignored case')
folded_input.ignore_ascii_case='yes'
expect(Search.scan(folded_input,archive).error=='invalid','non-boolean case setting accepted')
local unicode_raw='<html><body><p>中文 Élan Needle 结束</p></body></html>'
files['/unicode.epub']=fixture(input.book,'2',unicode_raw)
local unicode_input={book=input.book,chapter='2',paths={'/unicode.epub'},keyword='中文 Élan nEEDLE',from=1,
    ignore_ascii_case=true}
local unicode=Search.scan(unicode_input,archive)
expect(#unicode.hits==1 and unicode.hits[1].context:find('中文 Élan Needle',1,true),
    'mixed UTF-8 and English match did not retain original text')
unicode_input.keyword='中文 élan needle'
expect(#Search.scan(unicode_input,archive).hits==0,'non-ASCII characters were unexpectedly case-folded')
local unicode_row=assert(Target.row(input.book,'中文 Élan nEEDLE',unicode.hits[1]))
expect(Target.bind_file('/unicode.epub',input.book,unicode_row,12,archive).position,
    'folded UTF-8 match did not bind to the original source')
local row=assert(Target.row(input.book,input.keyword,first.hits[1]))
local bound=Target.bind_file('/cached.epub',input.book,row,9,archive)
expect(bound.position and bound.position.book_id==input.book and bound.position.upload_verified==false,
    'local result did not bind to a non-uploadable source target')
expect(bound.position.chapter_offset==first.hits[1].offset and bound.request_id==9,'bound target changed location')
local found=Target.resolve({book_id=input.book,cached_chapters={['2']='/cached.epub'}},'/missing.epub',row,10,archive)
expect(found.position and found.file=='/cached.epub','resolution did not use the downloaded chapter')
found=Target.resolve({book_id=input.book,cached_chapters={[2]='/cached.epub'}},'/missing.epub',row,10,archive)
expect(found.position and found.file=='/cached.epub','numeric chapter map keys did not resolve')
local original=files['/cached.epub'];files['/cached.epub']=fixture(input.book,'2',raw:gsub('needle','changed'))
expect(not Target.bind_file('/cached.epub',input.book,row,11,archive).position,'changed source was accepted')
files['/cached.epub']=original
expect(not Target.bind_file('/cached.epub','CB_Other',row,11,archive).position,'another book was accepted')
local meta=original[Source.meta_path('2')];original[Source.meta_path('2')]='invalid'
expect(Search.scan({book=input.book,chapter='2',paths={'/cached.epub'},keyword='needle',from=1},archive).missing,
    'invalid source metadata was treated as a searchable chapter')
original[Source.meta_path('2')]=meta
expect(Search.scan({book='CB_bad/path',chapter='2',paths={'/cached.epub'},keyword='x',from=1},archive).error=='invalid',
    'unsafe book identity was accepted')
expect(Search.scan({book=input.book,chapter='2',paths={'/cached.epub'},keyword='   ',from=1},archive).error=='invalid',
    'blank normalized query was accepted')
local full_book={book_id=input.book,bookVersion=7}
local chapters={{chapterUid='2'},{chapterUid='3'}}
local full_identity_text=Identity.encode(full_book,chapters,Identity.capture(full_book),Crypto.sha256_hex(raw))
local full_identity=assert(Identity.decode(full_identity_text))
local full_members={[Identity.PATH]=full_identity_text};local metadata={}
for index,chapter in ipairs(chapters) do
    local source=assert(Source.capture(full_book,chapter,raw,'web_xhtml'))
    local rendered=string.format('OEBPS/text/chapter-%03d.xhtml',index)
    local value=assert(Source.bind(source,full_identity,rendered,Crypto.sha256_hex(raw)))
    local name=Source.meta_path(chapter.chapterUid)
    full_members[name],full_members[Source.path_meta_path(rendered)]=value,value
    full_members[Source.raw_path(source.raw_sha256)],full_members[rendered]=raw,raw
    metadata[index]={name=name,metadata=value}
end
files['/full.epub']=full_members
local function list() return metadata end
local discovered=Search.discover({book=input.book,file='/full.epub'},archive,list)
expect(#discovered.entries==2 and discovered.entries[1].uid=='2' and discovered.entries[2].uid=='3'
    and not discovered.incomplete,'full-book index did not preserve chapter order')
expect(Search.scan({book=input.book,chapter='3',paths={'/full.epub'},keyword='needle',from=1},archive).hits[1],
    'discovered chapter did not pass independent source verification')
local partial=Search.discover({book=input.book,file='/full.epub'},archive,function() return {metadata[1]} end)
expect(#partial.entries==1 and partial.incomplete,'missing chapter metadata was not disclosed')
expect(Search.discover({book='CB_Other',file='/full.epub'},archive,list).error=='unavailable',
    'another book\'s full archive was accepted')
expect(Search.discover({book=input.book,file='/full.epub'},archive,function() return {metadata[1],metadata[1]} end).error=='ambiguous',
    'duplicate chapter metadata was accepted')
local tampered={{name=metadata[1].name,metadata=metadata[2].metadata}}
expect(Search.discover({book=input.book,file='/full.epub'},archive,function() return tampered end).incomplete,
    'mismatched metadata name was accepted')
print(('cached_book_search_spec: %d checks'):format(checks))
