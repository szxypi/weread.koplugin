package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(s)
    return s:gsub('&amp;','&'):gsub('&#x1F642;','🙂'):gsub('&NotEqualTilde;','≂̸')
end} end
local Point=require('weread.lib.bookmark_point');local Coordinates=require('weread.lib.source_coordinates')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function coordinate(raw,needle)
    local map=assert(Coordinates.build(raw,{allow_multiple_bodies=true}))
    local at=assert(map.flat:find(needle,1,true));return map:_point(at)
end
local function roundtrip(raw,needle)
    local co=coordinate(raw,needle);local value,why=Point.project(raw,co);assert(value,why)
    local row={type=0,chapterUid=2,range=value.range,markText=value.markText}
    local target=assert(Point.from_mark(raw,'41','2',row))
    expect(target.chapter_offset==co,'point did not roundtrip')
    expect(target.raw_sha256==value.raw_sha256 and target.raw_bytes==#raw,'source binding lost')
    expect(target.basis=='filtered_xhtml_utf16' and target.upload_verified==false,'navigation became upload permission')
    for _i,text in ipairs({'',false,'Unrelated text','\255','\0','\127'}) do
        row.markText=text
        if text=='' then expect(Point.from_mark(raw,'41','2',row)~=nil,'missing preview refused')
        else expect(not Point.from_mark(raw,'41','2',row),'invalid returned preview accepted') end
    end
    row.markText=nil;expect(Point.from_mark(raw,'41','2',row)~=nil,'absent preview refused')
    return value
end
local raw='<body><p>😀 Unique bookmark\r\nsource text with sufficient context.</p></body>'
local value=roundtrip(raw,'Unique')
expect(value.range=='11' and value.chapter_offset==12,'raw scalar and filtered UTF-16 units confused')
expect(value.markText:find('\r\n',1,true)~=nil,'CRLF preview normalized')
local bom=roundtrip('\239\187\191'..raw,'Unique')
expect(bom.range==value.range and bom.chapter_offset==value.chapter_offset+1,'BOM units confused')
roundtrip('<body><p>Prefix<a href="https://example.invalid/">Unique &amp; 😀 bookmark source</a> suffix.</p></body>','Unique')
roundtrip('<body><p>Unique &amp; bookmark source with enough context.</p></body>','&bookmark')
local long=roundtrip('<body><p>Unique '..string.rep('中文 😀 &amp; ',100)..'</p></body>','Unique')
local n=0;for _char in long.markText:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end
expect(n<=140 and not long.markText:find('&amp;',1,true),'preview quota/entity decoding failed')
for _i,point in ipairs({'01','-1','1-2','1.0','2147483648',false}) do expect(Point.point(point)==nil,'noncanonical point accepted') end
expect(Point.point('0')==0 and Point.point('2147483647')==2147483647,'valid endpoints refused')
for _i,row in ipairs({{type=1,chapterUid=2,range='12'},{type=0,chapterUid=3,range='12'},
    {type=0,chapterUid=2,range='0'},{type=0,chapterUid=2,range='999999'},
    {type=0,chapterUid=2,range='12',bookId='42'}}) do expect(not Point.from_mark(raw,'41','2',row),'wrong source scope accepted') end
local entity='<body><p>Unique &amp; bookmark context.</p></body>'
expect(not Point.from_mark(entity,'41','2',{type=0,chapterUid=2,range=tostring(assert(entity:find('&amp;',1,true)))}),'inside entity became nearest point')
expect(not Point.project(entity,#entity-7),'chapter end became nearest point')
local multi='<body><p>Unique &NotEqualTilde; bookmark context.</p></body>'
expect(not Point.project(multi,coordinate(multi,'≂̸')),'multiple entity scalars accepted as one point')
local imported_raw='<body><p>😀 Unique imported bookmark preview with sufficient distinct source context.</p></body>'
local imported_value=assert(Point.project(imported_raw,coordinate(imported_raw,'Unique')))
local imported_row={type=0,chapterUid=2,range=imported_value.range,markText=imported_value.markText}
local imported=assert(Point.from_mark(imported_raw,'CB_SyntheticNotes','2',imported_row))
expect(imported.chapter_offset==imported_value.chapter_offset and not imported.upload_verified,'imported point changed position or gained upload rights')
expect(Point.can_locate(imported_row,true),'unique imported preview hidden')
for _i,preview in ipairs({'','short','Wrong text that has enough distinct characters','\255','\0'}) do
    imported_row.markText=preview
    expect(not Point.from_mark(imported_raw,'CB_SyntheticNotes','2',imported_row),'invalid imported preview accepted')
end
imported_row.markText=nil
expect(not Point.can_locate(imported_row,true) and not Point.from_mark(imported_raw,'CB_SyntheticNotes','2',imported_row),'missing imported preview accepted')
imported_row.markText='Unique imported bookmark preview'
expect(not Point.from_mark('<body><p>Unique imported bookmark preview Unique imported bookmark preview</p></body>',
    'CB_SyntheticNotes','2',{type=0,chapterUid=2,range='9',markText=imported_row.markText}),'repeated imported preview accepted')
imported_row.bookId='CB_Other'
expect(not Point.from_mark(imported_raw,'CB_SyntheticNotes','2',imported_row),'foreign imported bookmark accepted')
local prefix='A self-authored test begins with one emoji: 😀.\n'
local txt_quote='A unique synthetic passage for testing a plain text bookmark.'
local txt=prefix..txt_quote..'\nA separate sentence provides context.'
local txt_row={type=0,chapterUid=2,range='48',markText=txt_quote}
local created=assert(Point.project(txt,48,'web_txt'))
expect(created.range=='48' and created.chapter_offset==48 and created.markText:find(txt_quote,1,true)==1,'TXT bookmark creation shifted')
local generated={type=0,chapterUid=2,range=created.range,markText=created.markText}
expect(assert(Point.from_mark(txt,'CB_SyntheticNotes','2',generated,'web_txt')).chapter_offset==48,'created TXT bookmark did not roundtrip')
local created_bom=assert(Point.project('\239\187\191'..txt,49,'web_txt'))
expect(created_bom.range=='48' and created_bom.markText==created.markText,'TXT BOM affected created bookmark')
expect(not Point.project(txt,45,'web_txt'),'surrogate midpoint accepted for TXT bookmark')
expect(not Point.project('😀 short',3,'web_txt'),'short TXT bookmark preview accepted')
local txt_point=assert(Point.from_mark(txt,'CB_SyntheticNotes','2',txt_row,'web_txt'))
expect(txt_point.chapter_offset==48 and txt_point.basis=='raw_txt_utf16' and not txt_point.upload_verified,'TXT UTF-16 point changed')
local prior={type=0,chapterUid=2,range='47',markText=txt_quote}
expect(assert(Point.from_mark(txt,'CB_SyntheticNotes','2',prior,'web_txt')).chapter_offset==48,'TXT scalar point changed')
expect(assert(Point.from_mark('\239\187\191'..txt,'CB_SyntheticNotes','2',txt_row,'web_txt')).chapter_offset==49,'TXT BOM changed point')
expect(assert(Point.prepare(txt,'CB_SyntheticNotes','2',txt_row,'web_txt')).anchor.co==48,'TXT bookmark anchor changed')
for _i,bad in ipairs({{range='49'},{range='45'},{markText='too short'},{markText='A different sufficiently long preview'},{bookId='CB_Other'}}) do
    local row={};for k,v in pairs(txt_row) do row[k]=v end;for k,v in pairs(bad) do row[k]=v end
    expect(not Point.from_mark(txt,'CB_SyntheticNotes','2',row,'web_txt'),'unverified TXT bookmark accepted')
end
expect(not Point.from_mark(txt,'CB_SyntheticNotes','2',{type=0,chapterUid=2,range='48'},'web_txt'),'TXT bookmark without preview accepted')
expect(not Point.from_mark(txt..txt_quote,'CB_SyntheticNotes','2',txt_row,'web_txt'),'duplicate TXT preview accepted')
print('bookmark_point_spec: '..checks..' checks')
