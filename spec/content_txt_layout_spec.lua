package.path='./?.lua;'..package.path
local Content=require('weread.lib.content')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function paragraphs(s)
    local result={}
    for body in s:gmatch('<p class="wr%-txt%-line">(.-)</p>') do result[#result+1]=body end
    return result
end
local raw='  First & <literal>  \r\n\r\n\tSecond  gap\n  \nLast\n'
local xhtml=Content.txt_to_xhtml(raw)
local p=paragraphs(xhtml)
expect(#p==5,'blank lines or terminal newline changed')
expect(p[1]=='&#160;&#160;First &amp; &lt;literal&gt;&#160;&#160;','indent, escaping or trailing spaces lost')
expect(p[2]=='&#160;','empty line vanished')
expect(p[3]=='&#160;&#160;&#160;&#160;Second&#160; gap','tab or internal repeated spaces collapsed')
expect(p[4]=='&#160;&#160;&#160;','whitespace-only line vanished')
expect(p[5]=='Last','last text changed')
expect(#paragraphs(Content.txt_to_xhtml(''))==0,'empty source gained a paragraph')
expect(#paragraphs(Content.txt_to_xhtml('one\n'))==1,'terminal newline gained a blank paragraph')
expect(#paragraphs(Content.txt_to_xhtml('one\n\n'))==2,'intentional final blank line disappeared')
local spaced=paragraphs(Content.txt_to_xhtml('x'..string.rep(' ',10000)..'y'))[1]
expect(spaced:find(' ',1,true)~=nil,'long whitespace lacks a line-break opportunity')
expect(Content.txt_to_xhtml('literal &amp; <tag>'):find('literal &amp;amp; &lt;tag&gt;',1,true), 'literal markup interpreted')
local bom=paragraphs(Content.txt_to_xhtml('\239\187\191 Indented'))[1]
expect(bom=='\239\187\191&#160;Indented','BOM-prefixed indentation collapsed')
expect(Content.txt_to_xhtml(raw,#xhtml)==xhtml,'rendered text rejected at the byte limit')
expect(not Content.txt_to_xhtml(raw,#xhtml-1),'rendered paragraphs exceeded the byte limit')
local whitespace='x'..string.rep(' ',512)..'y'
expect(not Content.txt_to_xhtml(whitespace,1024),'expanded whitespace exceeded the byte limit')
expect(not Content.txt_to_xhtml(string.rep('\n',512),1024),'expanded blank lines exceeded the byte limit')
print(('content_txt_layout_spec: %d checks'):format(checks))
