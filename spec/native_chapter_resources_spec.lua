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
denied(input('<p style="color:red">text</p>','',assets),'inline_style')
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
denied(input('<body background="foo.png">Text</body>','',{}),'background_attribute')
denied(input('<embed src="foo.bin"/>','',{}),'unsupported_markup')
denied(input('<p>\255</p>','',{}),'source')
local sparse=input('<p>text</p>','',assets);sparse.assets={[2]=assets[1]};denied(sparse,'assets')
denied(input('<p>text</p>','',{{source='images/a.png',data='not png',media_type='image/png'}}),'asset')
print('PASS: native chapter resource mapping, missing and ambiguous references')
