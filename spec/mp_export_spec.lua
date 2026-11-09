package.path='./?.lua;'..package.path
local Export=require('weread.lib.mp_export')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function decode(text)
    return (text:gsub('&lt;','<'):gsub('&gt;','>'):gsub('&quot;','"'):gsub('&amp;','&'):gsub('&#0;','\0'))
end
local function convert(body,resolve)
    return Export.convert('<html><head><title>Ignored</title></head><body>'..body..'</body></html>',resolve or function() end,decode,'未缓存图片')
end
local function rejected(html)
    local ok,err=pcall(Export.convert,html,function() end,decode)
    expect(not ok and tostring(err):match('^mp_export/'),'invalid input accepted')
end
local html,missing=convert('<h1>A &amp; B</h1><section><p>中文 &lt;文字&gt;<em> emphasized</em></p></section>')
expect(html=='<h1>A &amp; B</h1><div><p>中文 &lt;文字&gt;<em> emphasized</em></p></div>' and missing==0,'text/structure lost')
html=convert('<p>one<p>two<br>three<hr><p>four')
expect(html=='<p>one</p><p>two<br/>three<hr/></p><p>four</p>','implicit end tags or EOF normalization wrong')
html=convert('<table><tbody><tr><th colspan="2">Title</th></tr><tr><td>A<td>B</tr></tbody></table>')
expect(html:find('<th colspan="2">',1,true) and html:find('<td>A</td><td>B</td>',1,true),'table structure lost')
html=convert('<SCRIPT>if (a < b) secret()</SCRIPT><style>p{background:url(file:///secret)}</style><p onclick="secret()" style="display:none">kept</p><iframe src="http://bad">hidden</iframe><svg><text>hidden svg</text></svg><embed src="file:///secret">')
expect(html=='<p>kept</p>','active markup or styles survived')
html=convert('<unknown><b>kept</b> text</unknown><!-- hidden --><img src="https://host/private"><img src="file:///secret" alt="Missing &amp; escaped">')
expect(html=='<b>kept</b> text<span>[未缓存图片]</span><span>[Missing &amp; escaped]</span>','unknown container/omission placeholders wrong')
local requested={}
html,missing=convert('<img src="local.png" alt="pic"><img src="local.png"><img data-src="missing">',function(src)
    requested[#requested+1]=src;if src=='local.png' then return 'images/image-1.png' end
end)
expect(#requested==3 and missing==1 and html:find('src="images/image-1.png" alt="pic"',1,true),'image references changed')
html=convert('<p id="42">A</p><a href="#42">go</a><p id="42">B</p><a href="https://example.test/path?a=1&amp;b=2">external</a><a href="javascript:bad()">no</a><a href="file:///secret">no</a><a href="https://user@host/path">no</a>')
expect(html:find('id="mp-42"',1,true) and not html:find('id="mp-42"',html:find('id="mp-42"',1,true)+1,true),'duplicate IDs retained')
expect(html:find('href="#mp-42"',1,true) and html:find('href="https://example.test/path?a=1&amp;b=2"',1,true),'safe links lost')
expect(not html:find('javascript',1,true) and not html:find('file:',1,true) and not html:find('user@',1,true),'unsafe link survived')
html=convert('<a href="https://example.test">root</a>')
expect(html=='<a href="https://example.test">root</a>','HTTPS root URL was lost')
for _,bad in ipairs({'fragment','<body>no close','<body></body><body>twice</body>','<body><p a="unterminated></p></body>',
    '<body><img src="a" SRC="b"></body>','<body>\0</body>','<body>&#0;</body>','<body><img alt="&#0;"/></body>',
    '<body>\255</body>','<body>\239\191\190</body>','<body>\239\191\191</body>','<body><script>no close</body>'}) do rejected(bad) end
rejected('<body>'..string.rep('x',Export.MAX_HTML)..'</body>')
rejected('<body>'..string.rep('<span>',129)..'</body>')
local old=Export.MAX_NODES;Export.MAX_NODES=2;rejected('<body><p>one</p></body>');Export.MAX_NODES=old
for _,case in ipairs({{'\137PNG\r\n\26\n','image/png','png'},{'\255\216\255abc','image/jpeg','jpg'},
    {'GIF89a','image/gif','gif'},{'RIFFxxxxWEBP','image/webp','webp'},{'<svg>','', ''}}) do
    local mime,ext=Export.mime(case[1]);expect((mime or '')==case[2] and (ext or '')==case[3],'bitmap signature incorrect')
end
local identity={mode='file',dev=1,ino=2,size=3,modification=4}
expect(Export.same(identity,identity),'same identity rejected')
for _,key in ipairs({'mode','dev','ino','size','modification'}) do
    local copy={};for k,v in pairs(identity) do copy[k]=v end;copy[key]='changed'
    expect(not Export.same(identity,copy),'file change accepted')
end
expect(Export.directory({data_dir='/local/'})=='/local/exports/articles','export directory incorrect')
expect(Export.is_export_path({data_dir='/local'},'/local/exports/articles/test.epub'),'export path not excluded')
expect(not Export.is_export_path({data_dir='/local'},'/local/exports/articles-other/test.epub'),'path boundary not enforced')
expect(not Export.directory({data_dir='bad\0path'}),'invalid root accepted')
print('PASS: cached MP export conversion ('..checks..' checks)')
