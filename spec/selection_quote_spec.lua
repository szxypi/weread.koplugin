package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(s) return s:gsub('&amp;','&'):gsub('&lt;','<'):gsub('&gt;','>') end} end
local Quote=require('weread.lib.selection_quote');local Coordinates=require('weread.lib.source_coordinates')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function selected(raw,text,first,last)
    local found=assert(Coordinates.build(raw,{allow_multiple_bodies=true}):locate(text))
    local result,reason=Quote.project(raw,first or found.co,last or found.end_co,text)
    return result,reason,found
end
local text='Unique selected quote';local raw='<body><p>'..text..'</p></body>'
local result=assert(selected(raw,text));expect(result.range=='9-30','plain raw rune range')
expect(result.abstract==text and result.raw_bytes==#raw,'quote changed')
expect(assert(selected('\239\187\191'..raw,text)).range==result.range,'leading BOM became a raw quote index')
local escaped='<body><p>Unique &amp; 😀 selected quote.</p></body>'
local value,_,found=selected(escaped,'Unique & 😀 selected quote.')
expect(value and value.abstract=='Unique & 😀 selected quote.','entity/astral text')
expect(Quote.project(escaped,found.co,found.end_co-1,'wrong')==nil,'mismatch accepted')
for _i,point in ipairs({true,-1,0/0,math.huge,found.co+.5}) do expect(not Quote.project(escaped,point,found.end_co,text),'invalid boundary accepted') end
local cross='<body><p>Unique selected</p><p>\nquote across elements.</p></body>'
value=assert(selected(cross,'Unique selected\nquote across elements.'))
expect(value.abstract=='Unique selected\nquote across elements.','paragraph quote changed')
expect(not Quote.project(raw,9,30,'x'..text),'foreign selection accepted')
expect(not Quote.project(raw,9,30,'x'..string.rep('a',4096)),'oversize quote accepted')
expect(not Quote.project('<body>bad',9,30,text),'malformed source accepted')
print('selection_quote_spec: '..checks..' checks')
