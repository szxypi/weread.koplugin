-- Deterministic fallback-independent checks of folded-to-original positions.
package.path='./?.lua;'..package.path
package.preload['ffi/utf8proc']=function()
    local values={['É']='é',['é']='é',['E\204\129']='é',['e\204\129']='é',['ß']='ss',['Σ']='σ',['σ']='σ',['ς']='σ',
        ['S\204\135\204\163']='ṩ',['s\204\163\204\135']='ṩ',
        ['\226\128\141']='',['¨']=' ̈'}
    return {lowercase=function(value) return values[value] or value end}
end
package.preload['weread.lib.unicode_normalize']=function()
    local values={['é']='e\204\129',['ṩ']='s\204\163\204\135',['가']='가'}
    return {decompose=function(value) return values[value] or value end,
        is_combining=function(cp) return cp==0x0301 or cp==0x0307 or cp==0x0323 end}
end
local Unicode=require('weread.lib.unicode_search')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
expect(Unicode.available(),'Unicode folder unavailable')
local raw='αÉStraßeΣς😀끝'
local index=assert(Unicode.build(raw,1,'STRASSE'))
expect(index.text=='αe\204\129strasseσσ😀끝' and index.needle=='strasse','fold did not preserve expansions')
local first=assert(index.text:find(index.needle,1,true))
local original,_,start=index.locate(first)
local final,_,_,last=index.locate(first+#index.needle-1)
expect(start and raw:sub(original,original+6)=='Straße' and final>original and last==first+#index.needle-1,
    'expanded match did not map to source boundaries')
local expanded=index.text:find('ss',1,true)
local a,_,boundary,last_expanded=index.locate(expanded)
local b,_,inside=index.locate(expanded+1)
expect(a==b and boundary and not inside and last_expanded==expanded+1,'partial expansion accepted as a boundary')
local suffix=assert(Unicode.build(raw,original+1,'STRASSE'))
expect(not suffix.text:find(suffix.needle,1,true),'continuation repeated the earlier source match')
local partial=assert(Unicode.build('AÉB',3,'b'))
expect(partial.text=='b' and partial.locate(1)==4,'continuation did not skip UTF-8 continuation bytes')
local chunks=string.rep('É',1025)..'Straße'
local many=assert(Unicode.build(chunks,1,'STRASSE'))
local found=assert(many.text:find(many.needle,1,true))
local p,_,valid=many.locate(found)
expect(valid and p==2051,'sparse block lookup changed the source offset')
local ignored=assert(Unicode.build(string.rep('\226\128\141',513)..'É',1,'é'))
expect(ignored.locate(1)==1540,'casefold-ignorable blocks lost the source offset')
local empty,reason=Unicode.build('text',1,'\226\128\141')
expect(not empty and reason=='invalid','empty folded query was accepted')
expect(Unicode.canonical_available(),'canonical normalization unavailable')
local from_composed=assert(Unicode.build('ÉCOLE',1,'e\204\129cole'))
expect(from_composed.text==from_composed.needle and select(3,from_composed.locate(1)),
    'decomposed query did not bind to composed source')
local from_decomposed=assert(Unicode.build('E\204\129COLE',1,'école'))
expect(from_decomposed.text==from_decomposed.needle and select(3,from_decomposed.locate(1)),
    'composed query did not bind to decomposed source')
local hangul=assert(Unicode.build('가',1,'가'))
expect(hangul.text==hangul.needle,'Hangul canonical decomposition did not match')
local reordered=assert(Unicode.build('S\204\135\204\163',1,'s\204\163\204\135'))
expect(reordered.text==reordered.needle,'canonical combining-mark reordering did not match')
local partial_accent=assert(Unicode.build('E\204\129',1,'e'))
local source,_,starts,ends=partial_accent.locate(1)
expect(source==1 and starts and ends>#partial_accent.needle,'partial accent cluster was treated as a whole character')
local continuation=assert(Unicode.build('E\204\129E\204\129',2,'é'))
expect(continuation.text==continuation.needle and continuation.locate(1)==4,
    'continuation repeated a partially consumed accented cluster')


local compatibility=assert(Unicode.build('a¨b',1,'äb'))
expect(compatibility.text==compatibility.needle,'fold-generated whitespace was not ignored')

package.preload.util=function() return {htmlEntitiesToUtf8=function(v) return v end} end
local Search=require('weread.lib.cached_book_search')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Target=require('weread.lib.cached_search_target')
local chapter={chapterUid='2'};local book={book_id='CB_Synthetic',bookVersion=7}
local body='<html><body><p>One unique prefix Éclair and E\204\129clair Straße Σίσυφος distinct suffix.</p></body></html>'
local captured=assert(Source.capture(book,chapter,body,'web_xhtml'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(body))
local identity=assert(Identity.decode(root));local render='OEBPS/text/chapter.xhtml'
local metadata=assert(Source.bind(captured,identity,render,Crypto.sha256_hex(body)))
local files={[Identity.PATH]=root,[Source.meta_path('2')]=metadata,[Source.path_meta_path(render)]=metadata,
    [Source.raw_path(captured.raw_sha256)]=body,[render]=body}
local function archive(_,wanted)
    local result={};for name,limit in pairs(wanted) do if not files[name] or #files[name]>limit then return end;result[name]=files[name] end
    return result
end
local args={book=book.book_id,chapter='2',paths={'/fixture.epub'},keyword='STRASSE',from=1,ignore_ascii_case=true}
local found_hits=Search.scan(args,archive)
expect(#found_hits.hits==1 and found_hits.hits[1].context:find('Straße',1,true),'Unicode match did not retain original context')
local row=assert(Target.row(book.book_id,args.keyword,found_hits.hits[1]))
expect(Target.bind_file('/fixture.epub',book.book_id,row,1,archive).position,'folded match did not rebind to the original source')
args.keyword='s';local partial_hits=Search.scan(args,archive)
for _,hit in ipairs(partial_hits.hits) do expect(not hit.context:find('^ß'),'half of a casefold expansion was accepted') end
args.keyword='éCLAIR';local canonical_hits=Search.scan(args,archive)
expect(#canonical_hits.hits==2 and canonical_hits.hits[1].offset~=canonical_hits.hits[2].offset,
    'composed query did not find both source encodings')
args.keyword='E\204\129CLAIR';local decomposed_hits=Search.scan(args,archive)
expect(#decomposed_hits.hits==2 and decomposed_hits.hits[1].offset==canonical_hits.hits[1].offset
    and decomposed_hits.hits[2].offset==canonical_hits.hits[2].offset,'decomposed query changed source positions')
for _,hit in ipairs(decomposed_hits.hits) do
    local match=assert(Target.row(book.book_id,args.keyword,hit))
    expect(Target.bind_file('/fixture.epub',book.book_id,match,1,archive).position,'canonical match did not bind to source')
end
args.keyword='éCLAIR';args.ignore_ascii_case=false
expect(#Search.scan(args,archive).hits==0,'case-sensitive match changed')
body='<html><body><p>É E\204\129</p></body></html>'
captured=assert(Source.capture(book,chapter,body,'web_xhtml'))
root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(body));identity=assert(Identity.decode(root))
metadata=assert(Source.bind(captured,identity,render,Crypto.sha256_hex(body)))
files={[Identity.PATH]=root,[Source.meta_path('2')]=metadata,[Source.path_meta_path(render)]=metadata,
    [Source.raw_path(captured.raw_sha256)]=body,[render]=body}
args.keyword='e';args.ignore_ascii_case=true;args.from=1
expect(#Search.scan(args,archive).hits==0,'partial accented characters became searchable after normalization')

local paras={}
for i=1,37 do paras[#paras+1]=string.format('<p>Unique chapter passage %03d Straße ending %03d</p>',i,i) end
body='<html><body>'..table.concat(paras)..'</body></html>'
captured=assert(Source.capture(book,chapter,body,'web_xhtml'))
root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(body))
identity=assert(Identity.decode(root));metadata=assert(Source.bind(captured,identity,render,Crypto.sha256_hex(body)))
files={[Identity.PATH]=root,[Source.meta_path('2')]=metadata,[Source.path_meta_path(render)]=metadata,
    [Source.raw_path(captured.raw_sha256)]=body,[render]=body}
args.keyword='STRASSE';args.ignore_ascii_case=true;args.from=1
local batch=Search.scan(args,archive)
expect(#batch.hits==30 and batch.next_byte and not batch.complete,'Unicode first result batch failed')
args.from,args.capture_id=batch.next_byte,batch.capture_id
local more=Search.scan(args,archive)
expect(#more.hits==7 and more.complete and batch.hits[30].offset<more.hits[1].offset,'Unicode continuation lost or repeated results')
body='<html><body><p>Unique alpha '..string.rep('ß',105)..' S ends.</p></body></html>'
captured=assert(Source.capture(book,chapter,body,'web_xhtml'))
root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(body));identity=assert(Identity.decode(root))
metadata=assert(Source.bind(captured,identity,render,Crypto.sha256_hex(body)))
files={[Identity.PATH]=root,[Source.meta_path('2')]=metadata,[Source.path_meta_path(render)]=metadata,
    [Source.raw_path(captured.raw_sha256)]=body,[render]=body}
args.keyword='s';args.from,args.capture_id=1,nil
local positions,rounds={},0
repeat
    local result=Search.scan(args,archive)
    expect(not result.error,'invalid partial expansion stalled or failed')
    for _,hit in ipairs(result.hits) do positions[#positions+1]=hit.context end
    rounds=rounds+1;expect(rounds<8,'Unicode search did not advance across partial expansions')
    if result.complete then break end
    expect(result.next_byte>args.from,'Unicode continuation did not advance')
    args.from,args.capture_id=result.next_byte,result.capture_id
until false
expect(#positions==2,'partial expansion created or lost search results')


print(('unicode_search_spec: %d checks'):format(checks))
