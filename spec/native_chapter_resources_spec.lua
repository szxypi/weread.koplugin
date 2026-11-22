package.path='./?.lua;'..package.path
local Resources=require('weread.lib.native_chapter_resources')
local function input(body,css,assets)
    return {source_channel='eink',coordinate_source_authoritative=false,is_text=false,body=body,css=css,unusable_resources=0,
        body_parts={{source='text/7.xhtml',data=body}},style_parts={{source='style/book.css',data=css}},assets=assets or {}}
end
local png='\137PNG\r\n\26\nsynthetic image data'
local assets={{source='images/cover.png',data=png,media_type='image/png'}}
local body=[[<html><body><img alt="A > B" src="../images/cover.png"/><img src="https://example.invalid/remote.png"/></body></html>]]
local css=[[/* url(ignored) */ p{content:"url(ignored)";background:url('../images/cover.png')}]]
local prepared=assert(Resources.prepare(input(body,css,assets)))
local href=prepared.assets[1].href
assert(href:match('^images/eink%-[0-9a-f]+%.png$') and #prepared.assets==1)
assert(prepared.xhtml:find('src="../'..href..'"',1,true) and prepared.xhtml:find('https://example.invalid/remote.png',1,true))
assert(prepared.css:find('url("'..href..'")',1,true) and prepared.css:find('content:"url(ignored)"',1,true)
    and prepared.css:find('/* url(ignored) */',1,true))
assert(prepared.localized_references==2 and prepared.remote_references==1 and prepared.coordinate_source_authoritative==false)
assert(#prepared.remote_urls==1 and prepared.remote_urls[1]=='https://example.invalid/remote.png')
local escaped=input('<img src="https://img.qq.com/a.png?a=1&amp;b=2"/>',
    'p{background:url("https://img.qq.com/a.png?a=1&b=2")}',{})
local pending=assert(Resources.prepare(escaped))
assert(pending.remote_references==2 and #pending.remote_urls==1 and pending.xhtml:find('&amp;',1,true))
local remote_assets={{source='https://img.qq.com/a.png?a=1&b=2',data=png,media_type='image/png'}}
local offline=assert(Resources.prepare(escaped,remote_assets))
assert(offline.remote_references==0 and #offline.remote_urls==0 and offline.localized_references==2
    and offline.xhtml:find('../'..offline.assets[1].href,1,true) and offline.css:find(offline.assets[1].href,1,true))
local duplicate={{source='one/p.png',data=png..'a',media_type='image/png'},{source='one/sub/../p.png',data=png..'b',media_type='image/png'}}
local function denied(value,reason)
    local result,why=Resources.prepare(value);assert(not result and why=='native_resources/'..reason,tostring(why))
end
denied(input('<img src="../one/p.png"/>','',duplicate),'ambiguous')
denied(input('<img src="../unknown/p.png"/>','',duplicate),'missing')
denied(input('<img src="../unknown/z.png"/>','',duplicate),'missing')
denied(input('<img src="x%2Z.png"/>','',assets),'unsupported')
denied(input('<img src="../images/cover.png" srcset="other.png 2x"/>','',assets),'unsupported_markup')
local styled='<p style="width: 75%; color: red; font-size:0">text</p>'
assert(assert(Resources.prepare(input(styled,'',assets))).xhtml==styled,
    'simple inline typography and layout must remain intact')
local styled_image="<img STYLE='width:100%; height:auto' src=\"../images/cover.png\"/>"
local inline_image=assert(Resources.prepare(input(styled_image,'',assets)))
assert(inline_image.xhtml:find("STYLE='width:100%; height:auto'",1,true)
    and inline_image.xhtml:find('../'..inline_image.assets[1].href,1,true))
for _,tag in ipairs({
    '<p style=width:100%>text</p>',
    '<p style="width:1px" style="color:red">text</p>',
    '<p style="background:url(https://example.invalid/x)">text</p>',
    '<p style="width:expression(alert(1))">text</p>',
    '<p style="width:1px;@import x">text</p>',
    '<p style="width:1&amp;2">text</p>',
    '<p style="width:1\\70x">text</p>',
    '<p style="width:1px/*comment*/">text</p>',
    '<p style="unknown:10px">text</p>',
}) do denied(input(tag,'',assets),'inline_style') end
denied(input('<p>text</p>','@import "external.css";',assets),'css_import')
denied(input('<p>text</p>','p{background:url("../missing.png")}',assets),'missing')
local stale=input('<p>text</p>','',assets);stale.body='different';denied(stale,'source_changed')
local remote=assert(Resources.prepare(input('<img src="data:image/png;base64,AAAA"/>','',{})))
assert(remote.remote_references==0 and remote.xhtml:find('data:image/png;base64,AAAA',1,true))
local with_link=input('<html><head><link rel="stylesheet" type="text/css" href="../style/book.css"/></head><body>Text</body></html>',
    'p{color:black}',{})
local linked=assert(Resources.prepare(with_link));assert(not linked.xhtml:find('<link',1,true) and linked.css=='p{color:black}')
denied(input('<link rel="stylesheet" href="https://example.invalid/a.css"/>','',{}),'link_tag')
local multi=input('<p>Text</p>','a\nb',{})
multi.style_parts={{source='style/a.css',data='a'},{source='style/b.css',data='b'}};denied(multi,'multiple_styles')
local ordered_body='<html><head><link rel="stylesheet" href="../style/b.css"/>'
    ..'<link rel="stylesheet" href="../style/a.css"/></head><body>Text</body></html>'
local function ordered()
    local value=input(ordered_body,'p{color:red}\np{color:blue}',{})
    value.style_parts={{source='style/a.css',data='p{color:red}'},{source='style/b.css',data='p{color:blue}'}}
    return value
end
local cascade=assert(Resources.prepare(ordered()))
assert(cascade.css=='p{color:blue}\np{color:red}' and not cascade.xhtml:find('<link',1,true),
    'stylesheet cascade must follow the document, not archive order')
local two_parts=ordered()
two_parts.body_parts[2]={source='text/8.xhtml',data=ordered_body}
two_parts.body=ordered_body..'\n'..ordered_body
assert(assert(Resources.prepare(two_parts)).css==cascade.css,'matching chapter parts must retain one ordered cascade')
local multi_images=ordered()
multi_images.assets=assets
multi_images.style_parts[1].data='p{background:url(../images/cover.png)}'
multi_images.css=multi_images.style_parts[1].data..'\n'..multi_images.style_parts[2].data
local image_result=assert(Resources.prepare(multi_images))
assert(image_result.css:find(image_result.assets[1].href,1,true) and image_result.localized_references==1,
    'multi-sheet image paths must resolve from each original stylesheet')
local missing=ordered();missing.body_parts[1].data=ordered_body:gsub('<link rel="stylesheet" href="../style/a.css"/>','')
missing.body=missing.body_parts[1].data;denied(missing,'multiple_styles')
local repeated=ordered();repeated.body_parts[1].data=ordered_body:gsub('../style/a.css','../style/b.css')
repeated.body=repeated.body_parts[1].data;denied(repeated,'multiple_styles')
local divided=ordered()
local reversed=ordered_body:gsub('style/b%.css','style/tmp.css'):gsub('style/a%.css','style/b.css'):gsub('style/tmp%.css','style/a.css')
divided.body_parts[2]={source='text/8.xhtml',data=reversed}
divided.body=divided.body_parts[1].data..'\n'..divided.body_parts[2].data;denied(divided,'multiple_styles')
local atrule=ordered();atrule.style_parts[1].data='@media screen{p{color:red}}'
atrule.css=atrule.style_parts[1].data..'\n'..atrule.style_parts[2].data;denied(atrule,'multiple_styles')
local malformed=ordered();malformed.style_parts[1].data='p{color:red'
malformed.css=malformed.style_parts[1].data..'\n'..malformed.style_parts[2].data;denied(malformed,'multiple_styles')
local trailing=ordered();trailing.style_parts[1].data='p{color:red}unfinished'
trailing.css=trailing.style_parts[1].data..'\n'..trailing.style_parts[2].data;denied(trailing,'multiple_styles')
local escaped_css=ordered();escaped_css.style_parts[1].data='p{content:"@email }";color:red}/* trailing */'
escaped_css.css=escaped_css.style_parts[1].data..'\n'..escaped_css.style_parts[2].data
assert(Resources.prepare(escaped_css),'quoted symbols and trailing comments should preserve order')
denied(input('<body background="foo.png">Text</body>','',{}),'background_attribute')
denied(input('<embed src="foo.bin"/>','',{}),'unsupported_markup')
denied(input('<p>\255</p>','',{}),'source')
local sparse=input('<p>text</p>','',assets);sparse.assets={[2]=assets[1]};denied(sparse,'assets')
denied(input('<p>text</p>','',{{source='images/a.png',data='not png',media_type='image/png'}}),'asset')
print('PASS: native chapter resource mapping, missing and ambiguous references')
