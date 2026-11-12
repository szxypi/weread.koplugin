package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(v) return v:gsub('&amp;','&'):gsub('&lt;','<') end} end
local Span=require('weread.lib.my_mark_span');local Quote=require('weread.lib.selection_quote')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local raw='<body><p>Unique selected quote and following context.</p></body>'
local mark={type=1,chapterUid=2,range='9-30',markText='Unique selected quote'}
local value=assert(Span.prepare(raw,'41','2',mark));expect(value.first==9 and value.last==30,'exact endpoints changed')
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
print('my_mark_span_spec: '..checks..' checks')
