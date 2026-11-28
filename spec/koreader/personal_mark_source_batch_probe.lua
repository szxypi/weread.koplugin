-- Synthetic old/new source-anchor comparison using the packaged KOReader code.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local old=assert(loadfile(assert(arg[2])))();local current=require('weread.lib.my_mark_span')
local Raw=require('weread.lib.annotation_source');local json=require('json')
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
    local old_results,old_reasons=old.prepare_batch(raw,book,'2',rows,format)
    assert(same(actual,old_results) and same(reasons,old_reasons),'batch results changed')
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
local long='<body><p>'..string.rep('文😀 &amp; long text ',600)..'Unique ending for long source lookup.</p></body>'
local long_rows={}
for i=1,8 do long_rows[i]=row(long,'Unique ending for long source lookup.') end
compare(long,'41',long_rows,'web_xhtml')
local sources={
    '<body><p>Alpha &amp; 中文 😀 <b>inner</b> more &lt; end.</p><p>Tail text.</p></body>',
    '\239\187\191<html><body><!-- comment --><p>A &amp; B　multiple  spaces 😀.</p>'..
        '<script>Hidden stuff</script><p>Final words after the script.</p></body></html>',
    '<body><p>Some &bad entity text and a final phrase.</p></body>',
    '<body><p>'..string.rep('文字😀 &amp; repeated text ',180)..'ending content.</p></body>',
}
for seed=1,64 do
    local source=sources[(seed-1)%#sources+1]
    local size=count(source:gsub('^\239\187\191',''))
    local spans=Raw.index(source,{body_only=true});local rows={}
    for i=1,8 do
        local first=(seed*83+i*37)%(size-1)
        local last=math.min(size,first+1+(seed*17+i*11)%65)
        local range=first..'-'..last
        local quote=Raw.quote(spans,range)
        rows[i]={type=1,chapterUid=2,range=range,markText=quote~='' and quote or 'missing quotation'}
        if i==3 and seed%5==0 then rows[i].markText='mismatched quotation' end
    end
    compare(source,seed%2==0 and '41' or 'CB_Synthetic',rows,'web_xhtml')
end
local repeated='<body><p>'..string.rep('repeated ',30)..'</p></body>'
compare(repeated,'41',{row(repeated,'repeated repeated')},'web_xhtml')
local too_many={};for i=1,current.MAX_BATCH+1 do too_many[i]={type=1} end
assert(not current.prepare_batch(entities,'41','2',too_many,'web_xhtml'))

local raw=chapter(200,false);local rows={}
for i=1,8 do rows[i]=row(raw,string.format('Unique selection %04d',i*20)) end
local index_source=Raw.index;local indexes=0
Raw.index=function(...) indexes=indexes+1;return index_source(...) end
local function before()
    return assert(old.prepare_batch(raw,'41','2',rows,'web_xhtml'))
end
local function after() return assert(current.prepare_batch(raw,'41','2',rows,'web_xhtml')) end
local first=before();assert(indexes==8,'baseline did not index each highlight')
indexes=0;local second=after();assert(indexes==1 and same(first,second),'batch mapping or index count changed')
Raw.index=index_source
local function measure(fn)
    local started=os.clock();for _=1,3 do assert(same(fn(),first)) end;return (os.clock()-started)*1000
end
local before_ms,after_ms=measure(before),measure(after)
print('WEREAD_PERSONAL_MARK_SOURCE_BATCH='..json.encode{result='PASS',comparisons=comparisons,chapter_bytes=#raw,
    highlights=#rows,iterations=3,old_source_indexes=8,new_source_indexes=1,old_cpu_ms=before_ms,new_cpu_ms=after_ms})
