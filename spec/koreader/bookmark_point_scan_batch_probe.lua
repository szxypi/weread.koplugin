-- Compare source-bound bookmarks in an installed plugin with the prior implementation.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local old=assert(loadfile(assert(arg[2])))();local current=require('weread.lib.bookmark_point')
local Coordinates=require('weread.lib.source_coordinates');local Raw=require('weread.lib.annotation_source');local Dom=require('weread.lib.source_dom');local json=require('json')
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function count(text)
    local n=0;for _ in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end;return n
end
local function chapter(n,bom)
    local parts={bom and '\239\187\191<html><body>' or '<html><body>'}
    for i=1,n do parts[#parts+1]=string.format('<p>章节😀 %04d -- Unique selection %04d for reading &amp; testing.</p>',i,i) end
    parts[#parts+1]='</body></html>';return table.concat(parts)
end
local function row(raw,quote)
    local text=raw:gsub('^\239\187\191','');local at=assert(text:find(quote,1,true))
    return {type=0,chapterUid=2,range=tostring(count(text:sub(1,at-1))),markText=quote}
end
local comparisons=0
local function compare(raw,book,rows,format)
    local actual,reasons=current.prepare_batch(raw,book,'2',rows,format)
    assert(type(actual)=='table' and type(reasons)=='table')
    local old_values,old_reasons=old.prepare_batch(raw,book,'2',rows,format)
    assert(same(actual,old_values) and same(reasons,old_reasons),'bookmark batch changed')
    for i,item in ipairs(rows) do
        if item.type==0 then
            local expected,why=old.prepare(raw,book,'2',item,format)
            assert(same(actual[i],expected) and reasons[i]==why,'bookmark result or rejection changed')
            comparisons=comparisons+1
        else assert(actual[i]==nil and reasons[i]==nil) end
    end
end
for seed=1,64 do
    local raw=chapter(12+seed%7,seed%2==0);local rows={}
    for i=1,8 do
        local number=(seed*7+i*3)%(12+seed%7)+1
        rows[i]=row(raw,string.format('Unique selection %04d',number))
    end
    if seed%3==0 then rows[2].markText='incorrect preview' end
    if seed%4==0 then rows[4].range='0' end
    if seed%5==0 then rows[6].chapterUid=3 end
    if seed%6==0 then rows[1].markText=nil end
    if seed%7==0 then rows[8]={type=1} end
    if seed%8==0 then rows[7].bookId='foreign' end
    if seed%9==0 then rows[5].range='01' end
    compare(raw,seed%2==0 and 'CB_Synthetic' or '41',rows,'web_xhtml')
end
local prefix='A self-authored test begins with one emoji: 😀.\n'
local quote='A unique synthetic passage for testing a plain text bookmark.'
local txt=prefix..quote..'\nA separate sentence provides context.'
local txt_rows={{type=0,chapterUid=2,range='48',markText=quote},
    {type=0,chapterUid=2,range='47',markText=quote},{type=0,chapterUid=2,range='49',markText=quote}}
compare(txt,'CB_Synthetic',txt_rows,'web_txt');compare('\239\187\191'..txt,'CB_Synthetic',txt_rows,'web_txt')
local special='<body><p>Unique &amp; text and &NotEqualTilde; characters with sufficient context.</p></body>'
compare(special,'41',{row(special,'Unique'),row(special,'text'),{type=0,chapterUid=2,range='0001'},
    {type=0,chapterUid=2,range='999999'},row(special,'characters')},'web_xhtml')
local repeated='<body><p>'..string.rep('前缀 😀 &amp; repeated words ',260)..'Unique overlapping bookmark context at the end.</p></body>'
local base=tonumber(row(repeated,'Unique overlapping bookmark context at the end.').range)
for seed=1,16 do
    local points={}
    for i=1,8 do points[i]={type=0,chapterUid=2,range=tostring(base+(seed+i)%20)} end
    points[8].range=points[1].range
    compare(repeated,'41',points,'web_xhtml')
end
local multi='<body><p>Unique &NotEqualTilde; adjacent &amp; bookmark text with enough context.</p></body>'
local entity=row(multi,'&NotEqualTilde;');entity.markText=nil
compare(multi,'41',{row(multi,'Unique'),entity,row(multi,'adjacent'),row(multi,'bookmark')},'web_xhtml')
local variants={
    '<body><p>Start &amp; 中文 😀 <b>inner</b> more &lt; end.</p><p>Distinct final sentence.</p></body>',
    '\239\187\191<html><body><!-- comment --><p> First\r\nsecond　😀 &amp; third sentence.</p>'..
        '<script>Hidden text</script><p>Unique fourth paragraph with context.</p></body></html>',
    '<body><p>Unique &NotEqualTilde; multi scalar, &amp; entity, spaces and trailing text.</p></body>',
    '<body><p>Unique &broken entity with trailing prose and context.</p></body>',
    repeated,
}
for seed=1,128 do
    local source=variants[(seed-1)%#variants+1]
    local size=count(source:gsub('^\239\187\191',''));local points={}
    for i=1,8 do
        local at=(seed*37+i*13)%size
        points[i]={type=0,chapterUid=2,range=tostring(at)}
        if i==3 and seed%5==0 then points[i].markText='incorrect preview' end
        if i==6 and seed%7==0 then points[i].chapterUid=3 end
    end
    points[8].range=points[1].range
    compare(source,seed%2==0 and '41' or 'CB_Synthetic',points,'web_xhtml')
end
local many={};for i=1,current.MAX_BATCH+1 do many[i]={type=0} end
assert(not current.prepare_batch(special,'41','2',many,'web_xhtml'))

local raw=chapter(200,false);local rows={}
for i=1,8 do rows[i]=row(raw,string.format('Unique selection %04d',i*20)) end
local build,index,normalize=Coordinates.build,Raw.index,Dom.normalize;local builds,indexes,normalizations=0,0,0
Coordinates.build=function(...) builds=builds+1;return build(...) end
Raw.index=function(...) indexes=indexes+1;return index(...) end
Dom.normalize=function(...) normalizations=normalizations+1;return normalize(...) end
local function before()
    return assert(old.prepare_batch(raw,'41','2',rows,'web_xhtml'))
end
local function after() return assert(current.prepare_batch(raw,'41','2',rows,'web_xhtml')) end
local first=before();local before_normalizations=normalizations;assert(builds==1 and indexes==1,'baseline build count changed')
for i=1,#rows do assert(first[i] and first[i].anchor,'benchmark bookmark is not independently locatable') end
builds,indexes,normalizations=0,0,0;local second=after();local after_normalizations=normalizations
assert(builds==1 and indexes==1 and same(first,second) and before_normalizations>after_normalizations*2,
    'batch point, build or normalization count changed')
Coordinates.build,Raw.index,Dom.normalize=build,index,normalize
local function measure(fn)
    local started=os.clock();for _=1,3 do assert(same(fn(),first)) end;return (os.clock()-started)*1000
end
local before_ms,after_ms=measure(before),measure(after)
local single={rows[1]};local expected=assert(old.prepare_batch(raw,'41','2',single,'web_xhtml'))
assert(expected[1] and expected[1].anchor,'single bookmark is not independently locatable')
local function measure_single(api)
    local started=os.clock()
    for _=1,3 do assert(same(api.prepare_batch(raw,'41','2',single,'web_xhtml'),expected)) end
    return (os.clock()-started)*1000
end
local before_single,after_single=measure_single(old),measure_single(current)
print('WEREAD_BOOKMARK_POINT_SCAN_BATCH='..json.encode{result='PASS',comparisons=comparisons,chapter_bytes=#raw,
    bookmarks=#rows,iterations=3,old_normalizations=before_normalizations,new_normalizations=after_normalizations,
    old_cpu_ms=before_ms,new_cpu_ms=after_ms,old_single_cpu_ms=before_single,new_single_cpu_ms=after_single})
