package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(v) return v:gsub('&amp;','&'):gsub('&lt;','<') end} end
local Span=require('weread.lib.my_mark_span');local Quote=require('weread.lib.selection_quote')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local raw='<body><p>Unique selected quote and following context.</p></body>'
local mark={type=1,chapterUid=2,range='9-30',markText='Unique selected quote'}
local value=assert(Span.prepare(raw,'41','2',mark));expect(value.first==9 and value.last==30,'exact endpoints changed')
local imported=assert(Span.prepare(raw,'CB_SyntheticNotes','2',mark))
expect(imported.first==value.first and imported.last==value.last and imported.normalized_sha256==value.normalized_sha256,
    'imported span changed the verified native range')
expect(not Span.project(raw,'CB_SyntheticNotes','2',{type=1,chapterUid=2,range=mark.range,markText=mark.markText,bookId='CB_Other'}),
    'foreign imported mark accepted')
expect(value.first_anchor.co==9 and value.last_anchor.co==30,'anchors do not pin endpoints')
local reverse=assert(Quote.project(raw,value.first,value.last,mark.markText));expect(reverse.range==mark.range,'forward proof differs')
local bom=assert(Span.project('\239\187\191'..raw,'41','2',mark));expect(bom.first==10 and bom.last==31,'BOM units changed')
for _i,bad in ipairs({{type=0},{chapterUid=3},{bookId='42'},{range='9-99999'},{markText='Unique  selected quote'}}) do
    local row={};for k,v in pairs(mark) do row[k]=v end;for k,v in pairs(bad) do row[k]=v end
    expect(not Span.project(raw,'41','2',row),'invalid scope/range accepted')
end
local text='Beginning unique '..string.rep('long content ',400)..'unique ending.'
local long='<body><p>'..text..'</p></body>'
value=assert(Span.project(long,'41','2',{type=1,chapterUid=2,range='9-'..(9+#text),markText=text}))
expect(value.normalized_bytes>4096,'long cloud highlight truncated to editor quota')
local inline='<body><p>Unrelated generated footnote adjacency.</p><p>Unique &amp; selected <b>text</b> and ending context.</p></body>'
local start=assert(inline:find('Unique',1,true))-1
local ending=assert(inline:find(' and ending',1,true))-1
value=assert(Span.prepare(inline,'41','2',{type=1,chapterUid=2,range=start..'-'..ending,markText='Unique & selected text'}))
expect(value.first_anchor.point_offset==0 and value.first_anchor.text=='Unique&selectedtext','start anchor escaped verified selection')
expect(value.last_anchor.point_offset==19 and value.last_anchor.text=='Unique&selectedtext','end anchor escaped verified selection')
local txt_prefix='A self-authored test begins with one emoji: 😀.\n'
local txt_quote='A unique synthetic passage for testing a plain text highlight.'
local txt=txt_prefix..txt_quote..'\nA separate sentence provides context.'
local txt_mark={type=1,chapterUid=2,range='48-110',markText=txt_quote}
local txt_span=assert(Span.prepare(txt,'CB_SyntheticNotes','2',txt_mark,'web_txt'))
expect(txt_span.first==48 and txt_span.last==110,'TXT UTF-16 endpoints changed')
expect(txt_span.first_anchor.basis=='raw_txt_utf16' and txt_span.last_anchor.basis=='raw_txt_utf16','TXT anchor basis changed')
local prior={type=1,chapterUid=2,range='47-109',markText=txt_quote}
local scalar=assert(Span.prepare(txt,'CB_SyntheticNotes','2',prior,'web_txt'))
expect(scalar.first==txt_span.first and scalar.last==txt_span.last,'verified scalar range displayed at another place')
local txt_bom=assert(Span.prepare('\239\187\191'..txt,'CB_SyntheticNotes','2',txt_mark,'web_txt'))
expect(txt_bom.first==49 and txt_bom.last==111,'TXT BOM changed visible highlight')
local invalid={type=1,chapterUid=2,range='49-111',markText=txt_quote}
expect(not Span.prepare(txt,'CB_SyntheticNotes','2',invalid,'web_txt'),'mismatched TXT range was displayed')
local ambiguous='😀'..string.rep('a',64)
expect(not Span.prepare(ambiguous,'CB_SyntheticNotes','2',{type=1,chapterUid=2,range='2-14',markText=string.rep('a',12)},'web_txt'),
    'ambiguous TXT interpretation was displayed')
local Coordinates=require('weread.lib.source_coordinates');local build=Coordinates.build;local builds=0
local Raw=require('weread.lib.annotation_source');local index=Raw.index;local indexes=0
Coordinates.build=function(...) builds=builds+1;return build(...) end
Raw.index=function(...) indexes=indexes+1;return index(...) end
local bad={type=1,chapterUid=2,range='9-30',markText='changed quotation'}
local batch,reasons=Span.prepare_batch(raw,'41','2',{mark,bad,mark,mark},'web_xhtml')
expect(batch and batch[1] and not batch[2] and batch[3] and batch[4] and reasons[2]=='my_mark_span/quote',
    'invalid batch member changed neighboring highlights')
expect(builds==1 and indexes==1 and batch[1].first==9 and batch[1].last==30,
    'same source batch rebuilt its XHTML coordinate map or source index')
builds=0
local txt_batch=assert(Span.prepare_batch(txt,'CB_SyntheticNotes','2',{txt_mark,prior},'web_txt'))
expect(txt_batch[1] and txt_batch[2] and txt_batch[1].first==txt_span.first and txt_batch[2].last==txt_span.last,
    'shared TXT map changed verified boundaries')
expect(builds==3,'TXT batch did not reuse the span coordinate map')
local oversized={};for i=1,Span.MAX_BATCH+1 do oversized[i]=mark end
expect(not Span.prepare_batch(raw,'41','2',oversized,'web_xhtml'),'unbounded span batch accepted')
Coordinates.build=build
Raw.index=index
print('my_mark_span_spec: '..checks..' checks')
