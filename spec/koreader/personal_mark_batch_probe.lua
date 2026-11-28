-- Synthetic old/new source-anchor comparison using the packaged KOReader code.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local old=assert(loadfile(assert(arg[2])))();local current=require('weread.lib.my_mark_span')
local Coordinates=require('weread.lib.source_coordinates');local json=require('json')
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
local function row(raw,source_quote,visible)
    local without_bom=raw:gsub('^\239\187\191','')
    local start=assert(without_bom:find(source_quote,1,true))
    local first=count(without_bom:sub(1,start-1))
    return {bookmarkId='synthetic-'..first,type=1,chapterUid=2,
        range=tostring(first)..'-'..tostring(first+count(source_quote)),markText=visible or source_quote}
end
local function chapter(n,bom)
    local pieces={bom and '\239\187\191<html><body>' or '<html><body>'}
    for i=1,n do
        pieces[#pieces+1]=string.format('<p>章节😀 %04d -- Unique selection %04d for testing &amp; reading.</p>',i,i)
    end
    pieces[#pieces+1]='</body></html>';return table.concat(pieces)
end
local comparisons=0
local function compare(raw,book,rows,format)
    local actual,reasons=current.prepare_batch(raw,book,'2',rows,format)
    assert(type(actual)=='table' and type(reasons)=='table')
    for index,item in ipairs(rows) do
        if type(item)=='table' and item.type==1 then
            local expected,why=old.prepare(raw,book,'2',item,format)
            assert(same(actual[index],expected) and reasons[index]==why,'source span or failure reason changed')
            comparisons=comparisons+1
        else assert(actual[index]==nil and reasons[index]==nil) end
    end
end
for seed=1,40 do
    local raw=chapter(12+seed%7,seed%2==0);local rows={}
    for index=1,8 do
        local number=(seed*7+index*3)%(12+seed%7)+1
        local quote=string.format('Unique selection %04d',number)
        rows[index]=row(raw,quote)
    end
    if seed%3==0 then rows[2].markText='invalid quotation' end
    if seed%4==0 then rows[4].range='0-999999' end
    if seed%5==0 then rows[6].chapterUid=3 end
    if seed%7==0 then rows[8]={type=0,chapterUid=2,range='0'} end
    compare(raw,seed%2==0 and 'CB_Synthetic' or '41',rows,'web_xhtml')
end
local entities='<html><body><p>Unique &amp; selected <b>text</b> with inline content.</p></body></html>'
compare(entities,'41',{row(entities,'Unique &amp; selected <b>text','Unique & selected text')},'web_xhtml')
local txt_prefix='A self-authored test begins with one emoji: 😀.\n'
local txt_quote='A unique synthetic passage for testing a plain text highlight.'
local txt=txt_prefix..txt_quote..'\nA separate sentence provides context.'
local txt_rows={{type=1,chapterUid=2,range='48-110',markText=txt_quote},
    {type=1,chapterUid=2,range='47-109',markText=txt_quote},
    {type=1,chapterUid=2,range='49-111',markText=txt_quote}}
compare(txt,'CB_Synthetic',txt_rows,'web_txt');compare('\239\187\191'..txt,'CB_Synthetic',txt_rows,'web_txt')
local repeated='<body><p>'..string.rep('repeated ',30)..'</p></body>'
compare(repeated,'41',{row(repeated,'repeated repeated')},'web_xhtml')
local too_many={};for i=1,current.MAX_BATCH+1 do too_many[i]={type=1} end
assert(not current.prepare_batch(entities,'41','2',too_many,'web_xhtml'))

local raw=chapter(200,false);local rows={}
for i=1,8 do rows[i]=row(raw,string.format('Unique selection %04d',i*20)) end
local build=Coordinates.build;local builds=0
Coordinates.build=function(...) builds=builds+1;return build(...) end
local function before()
    local result={};for i,item in ipairs(rows) do result[i]=assert(old.prepare(raw,'41','2',item,'web_xhtml')) end;return result
end
local function after() return assert(current.prepare_batch(raw,'41','2',rows,'web_xhtml')) end
local first=before();assert(builds==16,'baseline did not build twice per highlight')
builds=0;local second=after();assert(builds==1 and same(first,second),'batch mapping or build count changed')
Coordinates.build=build
local function measure(fn)
    local started=os.clock();for _=1,3 do assert(same(fn(),first)) end;return (os.clock()-started)*1000
end
local before_ms,after_ms=measure(before),measure(after)
print('WEREAD_PERSONAL_MARK_BATCH='..json.encode{result='PASS',comparisons=comparisons,chapter_bytes=#raw,
    highlights=#rows,iterations=3,old_map_builds=16,new_map_builds=1,old_cpu_ms=before_ms,new_cpu_ms=after_ms})
