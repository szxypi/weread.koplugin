package.path='./?.lua;'..package.path
local Coordinates=require('weread.lib.source_coordinates')
local checks=0
local function expect(v,message) checks=checks+1;assert(v,message) end
local html='<html><body><p>Alpha&nbsp;beta <b>gamma</b> &amp; delta</p></body></html>'
local map=assert(Coordinates.build(html))
map:_index()
local start=assert(map.flat:find('Alphabeta',1,true))
expect(map:snippet(start,80)=='Alpha beta gamma & delta','XHTML context did not preserve spaces or decode entities')
expect(map:snippet(start,10)=='Alpha beta','context character limit was not respected')
expect(map:snippet(start,6)=='Alpha','context ended with an artificial trailing space')
local text='First  second\n third & literal <text>'
local txt=assert(Coordinates.build(text,{format='web_txt'}));txt:_index()
expect(txt:snippet(1,80)=='First second third & literal <text>','TXT context lost literal text or spacing')
local huge=assert(Coordinates.build('needle'..string.rep(' ',9000)..'later',{format='web_txt'}));huge:_index()
expect(huge:snippet(1,80)=='needle','context scanned beyond its bounded source window')
expect(not map:snippet(start,0) and not map:snippet(start,161),'unbounded context accepted')
print(('source_context_snippet_spec: %d checks'):format(checks))
