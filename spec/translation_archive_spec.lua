package.path='./?.lua;'..package.path
local Archive=require('weread.lib.translation_archive')
local Identity=require('weread.lib.book_file_identity')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fails(task)
    local ok,err=pcall(task);expect(not ok and tostring(err):match('^translation_archive/'),'invalid package accepted')
end
local container='<container><rootfiles><rootfile media-type="application/oebps-package+xml" full-path="OPS/package.opf"/></rootfiles></container>'
expect(Archive.container(container)=='OPS/package.opf','container path not parsed')
local opf=[[<package unique-identifier="bookid"><metadata><dc:identifier id="bookid">weread-42-full</dc:identifier></metadata>
<manifest><item id="second" href="text/second.xhtml" media-type="application/xhtml+xml"/><item id="first" href="text/first.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="first"/><itemref idref="second"/></spine></package>]]
local plan=Archive.plan('OPS/package.opf',opf,'42')
expect(plan.members[1]=='OPS/text/first.xhtml' and plan.members[2]=='OPS/text/second.xhtml','manifest order replaced spine order')
expect(plan.file_id=='' and #plan.opf_sha256==64,'legacy package binding absent')
local identity=Identity.encode({book_id='42'},{{},{}},nil,string.rep('a',64))
expect(#Archive.plan('OPS/package.opf',opf,'42',identity).file_id==64,'embedded file identity not checked')
fails(function() Archive.plan('OPS/package.opf',opf,'43') end)
fails(function() Archive.plan('OPS/package.opf',opf,'42','broken') end)
fails(function() Archive.plan('OPS/package.opf',opf,'42',Identity.encode({book_id='43'},{{},{}},nil,string.rep('a',64))) end)
fails(function() Archive.plan('OPS/package.opf',opf,'42',Identity.encode({book_id='42'},{{}},nil,string.rep('a',64))) end)
for _,bad in ipairs({
    opf:gsub('id="second"','id="first"'),
    opf:gsub('idref="second"','idref="first"'),
    opf:gsub('idref="second"','idref="missing"'),
    opf:gsub('idref="second"','idref="second" linear="no"'),
    opf:gsub('text/first.xhtml','../../../escape.xhtml'),
    opf:gsub('text/first.xhtml','https://example.invalid/book.xhtml'),
    opf:gsub('href="text/first.xhtml"','href="text/first.xhtml" href="other.xhtml"'),
    '<!DOCTYPE package [<!ENTITY x SYSTEM "file:///secret">]>'..opf,
    opf..opf,
    opf:gsub('</spine>','</wrong>'),
}) do fails(function() Archive.plan('OPS/package.opf',bad,'42') end) end
for _,path in ipairs({'../escape','%2e%2e/escape','/root','x\\y','https://host/x','bad%zz','x#fragment','x?query','x%00'}) do
    fails(function() Archive.path('',path) end)
end
expect(Archive.path('OPS/','../text/a%20b.xhtml')=='text/a b.xhtml','valid relative path or percent encoding changed')
expect(Archive.container(container:gsub('OPS/package.opf','OPS/a&amp;b.opf'))=='OPS/a&b.opf','XML attribute entity lost')
print('PASS: translation EPUB layout ('..checks..' checks)')
