-- Compare source-bound bookmarks in an installed plugin with the prior implementation.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local old=assert(loadfile(assert(arg[2])))();local current=require('weread.lib.bookmark_point')
local Coordinates=require('weread.lib.source_coordinates');local Raw=require('weread.lib.annotation_source');local json=require('json')
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
local many={};for i=1,current.MAX_BATCH+1 do many[i]={type=0} end
assert(not current.prepare_batch(special,'41','2',many,'web_xhtml'))

local raw=chapter(200,false);local rows={}
for i=1,8 do rows[i]=row(raw,string.format('Unique selection %04d',i*20)) end
local build,index=Coordinates.build,Raw.index;local builds,indexes=0,0
Coordinates.build=function(...) builds=builds+1;return build(...) end
Raw.index=function(...) indexes=indexes+1;return index(...) end
local function before()
    local result={};for i,item in ipairs(rows) do result[i]=assert(old.prepare(raw,'41','2',item,'web_xhtml')) end;return result
end
local function after() return assert(current.prepare_batch(raw,'41','2',rows,'web_xhtml')) end
local first=before();assert(builds==16 and indexes==8,'baseline build count changed')
builds,indexes=0,0;local second=after()
assert(builds==1 and indexes==1 and same(first,second),'batch point or build count changed')
Coordinates.build,Raw.index=build,index
local function measure(fn)
    local started=os.clock();for _=1,3 do assert(same(fn(),first)) end;return (os.clock()-started)*1000
end
local before_ms,after_ms=measure(before),measure(after)
print('WEREAD_BOOKMARK_POINT_BATCH='..json.encode{result='PASS',comparisons=comparisons,chapter_bytes=#raw,
    bookmarks=#rows,iterations=3,old_map_builds=16,new_map_builds=1,old_source_indexes=8,new_source_indexes=1,
    old_cpu_ms=before_ms,new_cpu_ms=after_ms})
