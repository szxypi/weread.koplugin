package.path='./?.lua;'..package.path
local Quote=require('weread.lib.selection_txt_quote')
local Coordinates=require('weread.lib.source_coordinates')
local Dom=require('weread.lib.source_dom')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function locate(raw,text)
    local map=assert(Coordinates.build(raw,{format='web_txt'}));local point=assert(map:locate(text))
    return point.co,point.end_co
end
local text='A unique synthetic passage for testing a plain text highlight.'
local raw='A self-authored test begins with one emoji: 😀.\n'..text..'\n'
local first,last=locate(raw,text);local result=assert(Quote.project(raw,first,last,text))
expect(result.range=='48-110' and result.abstract==text and result.raw_bytes==#raw,'UTF-16 range after emoji')
expect(first==48 and last==110,'fixture did not distinguish UTF-16 from rune offsets')
local with_bom='\239\187\191'..raw;local bom_first,bom_last=locate(with_bom,text)
local bom=assert(Quote.project(with_bom,bom_first,bom_last,text))
expect(bom.range==result.range and bom.abstract==text and bom_first==first+1,'BOM handling changed quote range')
local literal='before &amp; <text> 😀\r\nUnique literal quote &amp; remains.'
local literal_text='Unique literal quote &amp; remains.'
first,last=locate(literal,literal_text);result=assert(Quote.project(literal,first,last,literal_text))
expect(result.abstract==literal_text,'literal TXT entities or angle brackets were decoded')
local line='Unique first line\r\n  second line.'
first,last=locate(line,'Unique first line second line.');result=assert(Quote.project(line,first,last,'Unique first line second line.'))
expect(result.abstract==line,'CRLF and indentation were not retained')
local emoji='A unique passage 😀 with emoji boundary.'
first,last=locate(emoji,emoji);result=assert(Quote.project(emoji,first,last,emoji))
expect(result.abstract==emoji,'selection spanning an emoji failed')
local emoji_start=assert(Coordinates.build(emoji,{format='web_txt'}):locate('A unique passage 😀 with emoji boundary.')).co+17
expect(not Quote.project(emoji,emoji_start+1,last,'with emoji boundary.'),'surrogate midpoint was accepted')
expect(not Quote.project(raw,first,last,'different selected text'),'mismatched selection accepted')
for _i,value in ipairs({true,-1,0/0,math.huge,1.5}) do expect(not Quote.project(raw,value,20,text),'invalid endpoint accepted') end
expect(not Quote.project(raw,0,10,string.rep('x',4097)),'oversized selection accepted')
expect(not Quote.project('bad\255',0,3,'bad'),'invalid UTF-8 source accepted')
expect(not Quote.project(with_bom,0,bom_last,'\239\187\191'..raw),'BOM was accepted inside selection')
expect(not Quote.project(raw,0,first,'\0'),'control character accepted')
local function scalar_count(value)
    local total=0;for _char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do total=total+1 end;return total
end
local prefix='A self-authored test begins with one emoji: 😀.\n'
local anchor=assert(Dom.normalize(raw));local selected=assert(Dom.normalize(text))
local a={text=anchor,point_offset=scalar_count(assert(Dom.normalize(prefix)))}
local b={text=anchor,point_offset=a.point_offset+scalar_count(selected)}
local from_context=assert(Quote.project_context(raw,a,b,text))
expect(from_context.range=='48-110' and from_context.abstract==text,'native contexts projected the wrong raw range')
local surrounding=assert(Quote.project(raw,47,110,text))
expect(surrounding.range=='48-110' and surrounding.abstract==text,'outer newline was not excluded from candidate range')
expect(not Quote.project_context(raw,a,b,text..' altered'),'changed native selected text accepted')
expect(not Quote.project_context(raw,{text=anchor..' ',point_offset=a.point_offset},b,text),
    'unnormalized native context accepted')
expect(not Quote.project_context(raw,{text=anchor,point_offset=10000},b,text),'out-of-range native point accepted')
local duplicate=prefix..text..'\n'..prefix..text..'\n'
expect(not Quote.project_context(duplicate,a,b,text),'ambiguous repeated contexts accepted')
print('selection_txt_quote_spec: '..checks..' checks')
