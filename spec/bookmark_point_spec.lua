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
print('bookmark_point_spec: '..checks..' checks')
