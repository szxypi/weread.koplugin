package.path='./?.lua;' .. package.path
local Guard=require('weread.lib.rich_footnotes')
local count=0
local function check(value, message) count=count+1; assert(value, message) end
for _i, tag in ipairs({'img','svg','math','table','object','video','audio','embed','iframe','image'}) do
    check(Guard.requires_original('<aside><' .. tag .. '/></aside>'), tag .. ' uses original')
end
for _i, html in ipairs({
    '<aside><svg:svg/></aside>', '<MATH><mi>x</mi></MATH>',
    '<a href="#reference">查看资料</a>', '<a HREF="https://example.org">资料</a>',
    '<a href="chapter.xhtml#note">另一处注释</a>',
    '<a title="a > b" href="#reference">资料</a>',
}) do check(Guard.requires_original(html), 'media/citation recognized') end
for _i, html in ipairs({
    '<p>普通文字 &lt;img/&gt;</p>', '<a href="#wrfnref-179-1">[1]</a>文字',
    '<a href="#_doc_fragment_0_ wrfnref-179-1" class="wr-fn-num">[文]</a>文字',
    '<a href="chapter.xhtml#_doc_fragment_12_wrfnref-179-1">[文]</a>',
    '<a href="#ref">↩</a>文字', '<a id="alias"/>文字',
    '<p title="<img> and >">文字</p>', '<!-- <img/> --><p>文字</p>',
    '<![CDATA[<table/>]]><p>文字</p>', '<p>残缺<tag',
}) do check(not Guard.requires_original(html), 'plain/return/escaped text stays native') end
check(not Guard.requires_original(nil), 'nil native extraction stays native')
local html='<p>文字</p>'
local proto={getHTMLFromXPointer=function() return html, nil, 'third' end,
    getHTMLFromXPointers=function() return html end}
local document=setmetatable({}, {__index=proto})
local calls=0
local original=function(link, a, b)
    calls=calls+1; check(link.marker and a=='argument' and b==17, 'arguments unchanged')
    local value, none, third=document:getHTMLFromXPointer('target', 0x1001, true)
    check(value==html and none==nil and third=='third', 'extraction returns preserved')
    return 'popup', nil, 17
end
local link={marker=true, showAsFootnotePopup=original}
local host={ui={document=document, link=link}, _current_weread_book_id='synthetic'}
check(Guard.attach(host), 'instance guard installed')
local value, none, third=link:showAsFootnotePopup('argument',17)
check(value=='popup' and none==nil and third==17 and calls==1, 'native result preserved')
check(rawget(document,'getHTMLFromXPointer')==nil and document.getHTMLFromXPointer==proto.getHTMLFromXPointer,
    'inherited methods restored exactly')
html='<img src="book.svg"/>'
check(link:showAsFootnotePopup('argument',17)==false, 'rich original requested before native popup creation')
check(rawget(document,'getHTMLFromXPointer')==nil, 'rich early abort restores methods')
Guard.detach(host); check(link.showAsFootnotePopup==original, 'detach restores native instance')
local failure={}
link.showAsFootnotePopup=function() document:getHTMLFromXPointers('start','end'); error(failure,0) end
Guard.attach(host)
check(link:showAsFootnotePopup()==false, 'extended native range is checked')
check(rawget(document,'getHTMLFromXPointers')==nil, 'extended extraction restored')
html='<p>文字</p>'
local ok, err=pcall(link.showAsFootnotePopup, link)
check(not ok and err==failure, 'unrelated native error propagated unchanged')
check(rawget(document,'getHTMLFromXPointer')==nil and rawget(document,'getHTMLFromXPointers')==nil,
    'all methods restored on native error')
local another=function() return 'another hook' end
link.showAsFootnotePopup=another
Guard.detach(host); check(link.showAsFootnotePopup==another, 'detach preserves a later hook')
Guard.attach(host); local previous_document=host.ui.document; host.ui.document={}
check(link:showAsFootnotePopup()=='another hook' and previous_document.getHTMLFromXPointer==proto.getHTMLFromXPointer,
    'changed document bypasses stale guard')
Guard.detach(host)
host._current_weread_book_id=nil
check(not Guard.attach(host) and link.showAsFootnotePopup==another, 'ordinary local books untouched')
check(not Guard.attach({}), 'unavailable native reader is harmless')
print('rich_footnotes_spec: ' .. count .. ' checks passed')
