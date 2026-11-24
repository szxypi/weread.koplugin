package.path='./?.lua;'..package.path
local Remote=require('weread.lib.native_chapter_remote')
local png='\137PNG\r\n\26\nsynthetic image'
local ref='https://img.qq.com/image.png?a=1&b=2'
local body='<img src="https://img.qq.com/image.png?a=1&amp;b=2"/>'
local css='p{background:url("'..ref..'")}'
local source={book_id='42',chapter_uid='7',book_version=1,catalog_sha256=string.rep('a',64),
    source_channel='eink',coordinate_source_authoritative=false,is_text=false,body=body,css=css,assets={},
    unusable_resources=0,body_parts={{source='text/7.xhtml',data=body}},style_parts={{source='style/book.css',data=css}}}
local calls,mode,alive=0,'ok',true
local client={request=function(_self,request)
    calls=calls+1
    assert(request.url==ref and request.method=='GET' and request.skip_cookie==true
        and request.persist_response_cookies==false and request.sensitive==true)
    assert(not request.headers.Cookie and not request.headers.vid and not request.headers.accessToken)
    if mode=='rate' then return nil,429,{} end
    if mode=='redirect' then return nil,302,{location='https://evil.invalid/'} end
    if mode=='changed' then alive=false end
    if mode=='source_changed' then source.body_parts[1].data=source.body_parts[1].data..'changed' end
    if mode=='large' then assert(not request.sink(string.rep('x',8*1024*1024+1)));return nil,200,{} end
    request.sink(mode=='bad_image' and 'not an image' or png)
    return nil,200,{}
end}
local options={is_current=function() return alive end}
local result=assert(Remote.complete(client,source,options))
assert(calls==1 and result.downloaded_images==1 and result.remote_references==0 and #result.assets==1)
assert(result.xhtml:find('../'..result.assets[1].href,1,true) and result.css:find(result.assets[1].href,1,true))
assert(result.assets[1].data==png and result.coordinate_source_authoritative==false)
for _,case in ipairs({{'rate','rate_limited'},{'redirect','unavailable'},{'changed','session_changed'},
    {'large','unavailable'},{'bad_image','invalid_image'},{'source_changed','source_changed'}}) do
    mode,calls,alive=case[1],0,true
    local value,reason=Remote.complete(client,source,options)
    assert(not value and reason==case[2] and calls==1,case[1])
end
source.body_parts[1].data=body
local fallback={is_current=function() return alive end,allow_missing_images=true}
for _,failure in ipairs({'redirect','large','bad_image'}) do
    mode,calls,alive=failure,0,true
    local placeholder=assert(Remote.complete(client,source,fallback))
    assert(placeholder.missing_images==1 and placeholder.downloaded_images==0 and #placeholder.assets==1
        and placeholder.assets[1].data==require('weread.lib.native_missing_image')
        and placeholder.xhtml:find('../'..placeholder.assets[1].href,1,true),failure)
end
mode,calls,alive='rate',0,true
local stopped,stop_reason=Remote.complete(client,source,fallback)
assert(not stopped and stop_reason=='rate_limited' and calls==1,'image fallback bypassed rate limiting')
mode,calls,alive='ok',0,true;source.catalog_sha256='invalid'
local value,reason=Remote.complete(client,source,options)
assert(not value and reason=='invalid_source' and calls==0)
source.catalog_sha256=string.rep('a',64)
mode,calls,alive='ok',0,false
value,reason=Remote.complete(client,source,options)
assert(not value and reason=='session_changed' and calls==0)
for _,url in ipairs({'http://img.qq.com/a','https://127.0.0.1/a','https://qq.com.evil.invalid/a',
    'https://user@img.qq.com/a','https://img.qq.com:444/a','https://img.qq.com/a#fragment'}) do
    assert(not Remote.allowed(url),url)
end
assert(Remote.allowed('//img.qq.com/a')=='https://img.qq.com/a')
assert(Remote.allowed('https://img.qq.com:443/a')=='https://img.qq.com:443/a')
assert(Remote.allowed('HTTPS://img.qq.com/a')=='https://img.qq.com/a')
assert(Remote.allowed('https://download.sz.gfp.tencent-cloud.com/a'))
assert(not Remote.allowed('https://gfp.tencent-cloud.com.evil.invalid/a'))
-- Each redirect is independently checked, the original credential-free
-- request is rebuilt, and response bytes from a redirect are discarded.
local target='https://download.sz.gfp.tencent-cloud.com/final.png'
local function redirect_case(kind)
    local seen={};local live=true
    local redirected={request=function(_self,request)
        seen[#seen+1]=request.url
        assert(request.skip_cookie and request.persist_response_cookies==false and request.sensitive)
        assert(not request.headers.Cookie and not request.headers.vid and not request.headers.accessToken)
        if #seen==1 then
            request.sink('redirect body')
            if kind=='cancel' then live=false end
            local location=kind=='bad' and 'https://evil.invalid/a' or kind=='downgrade' and 'http://img.qq.com/a'
                or kind=='relative' and '/final.png' or kind=='loop' and ref or target
            return nil,302,{location=location}
        end
        if kind=='rate' then return nil,429,{} end
        request.sink(png);return nil,200,{}
    end}
    local got,why=Remote.complete(redirected,source,{is_current=function() return live end})
    if kind=='good' or kind=='relative' then
        assert(got and #seen==2 and got.assets[1].data==png and got.downloaded_images==1)
        assert(seen[2]==(kind=='relative' and 'https://img.qq.com/final.png' or target))
    else
        assert(not got and #seen==(kind=='rate' and 2 or 1))
        assert(why==(kind=='cancel' and 'session_changed' or kind=='rate' and 'rate_limited' or 'unavailable'))
    end
end
for _,kind in ipairs({'good','relative','bad','downgrade','loop','rate','cancel'}) do redirect_case(kind) end
local hop_count=0;alive=true
local looping={request=function(_self,_request)
    hop_count=hop_count+1
    return nil,302,{location='https://img.qq.com/hop'..hop_count..'.png'}
end}
local stopped_hops,hop_reason=Remote.complete(looping,source,options)
assert(not stopped_hops and hop_reason=='unavailable' and hop_count==4,'redirect limit was not enforced')
local unsafe={book_id='42',chapter_uid='7',book_version=1,catalog_sha256=string.rep('a',64),
    source_channel='eink',coordinate_source_authoritative=false,is_text=false,unusable_resources=0,
    body='<img src="https://evil.invalid/a"/>',css='',assets={},
    body_parts={{source='text/7.xhtml',data='<img src="https://evil.invalid/a"/>'}},style_parts={}}
calls,alive=0,true;value,reason=Remote.complete(client,unsafe,options)
assert(not value and reason=='remote_unsupported' and calls==0)
local replacement=assert(Remote.complete(client,unsafe,fallback))
assert(replacement.missing_images==1 and calls==0 and not replacement.xhtml:find('evil.invalid',1,true))
local mixed_body='<img src="../lost.png"/><img src="https://img.qq.com/image.png?a=1&amp;b=2"/>'
local mixed={book_id='42',chapter_uid='7',book_version=1,catalog_sha256=string.rep('a',64),
    source_channel='eink',coordinate_source_authoritative=false,is_text=false,unusable_resources=0,
    body=mixed_body,css='',assets={},body_parts={{source='text/7.xhtml',data=mixed_body}},style_parts={}}
mode,calls,alive='redirect',0,true
local mixed_result=assert(Remote.complete(client,mixed,fallback))
assert(mixed_result.missing_images==2 and mixed_result.missing_local_images==1 and calls==1
    and #mixed_result.assets==1,'local and remote placeholders did not share asset or counts')
local many={}
for i=1,65 do many[#many+1]='<img src="https://img.qq.com/'..i..'.png"/>' end
local large_body=table.concat(many)
local too_many={book_id='42',chapter_uid='7',book_version=1,catalog_sha256=string.rep('a',64),
    source_channel='eink',coordinate_source_authoritative=false,is_text=false,unusable_resources=0,
    body=large_body,css='',assets={},body_parts={{source='text/7.xhtml',data=large_body}},style_parts={}}
calls=0;value,reason=Remote.complete(client,too_many,options)
assert(not value and reason=='native_resources/remote_limit' and calls==0)

-- A chapter with no remote resources is prepared once, but still passes the
-- same source and session checks before its first result is returned.
local Resources=require('weread.lib.native_chapter_resources')
local original_prepare=Resources.prepare
local prepares=0
Resources.prepare=function(...) prepares=prepares+1;return original_prepare(...) end
local function local_source(html,assets)
    return {book_id='42',chapter_uid='7',book_version=1,catalog_sha256=string.rep('a',64),
        source_channel='eink',coordinate_source_authoritative=false,is_text=false,unusable_resources=0,
        body=html,css='',assets=assets or {},body_parts={{source='text/7.xhtml',data=html}},style_parts={}}
end
alive=true
local plain=local_source('<p>纯文字章节</p>')
local local_result=assert(Remote.complete(client,plain,options))
assert(prepares==1 and local_result.xhtml==plain.body and local_result.downloaded_images==0 and calls==0)
prepares=0
local local_image=local_source('<link rel="stylesheet" href="../style/book.css"/><img src="../cover.png"/>',
    {{source='cover.png',data=png,media_type='image/png'}})
local_image.css='p{background:url("../cover.png")}'
local_image.style_parts={{source='style/book.css',data=local_image.css}}
local_result=assert(Remote.complete(client,local_image,options))
assert(prepares==1 and #local_result.assets==1 and local_result.localized_references==2
    and local_result.css:find(local_result.assets[1].href,1,true))
prepares=0
local missing_local=local_source('<img src="../missing.png"/>')
local_result=assert(Remote.complete(client,missing_local,fallback))
assert(prepares==1 and local_result.missing_images==1 and #local_result.assets==1)
prepares=0
local changed=local_source('<p>正文</p>');local checks=0
value,reason=Remote.complete(client,changed,{is_current=function()
    checks=checks+1
    if checks==2 then changed.body_parts[1].data='different' end
    return true
end})
assert(not value and reason=='source_changed' and prepares==1,'changed source reused stale preparation')
prepares=0;checks=0
value,reason=Remote.complete(client,plain,{is_current=function() checks=checks+1;return checks<2 end})
assert(not value and reason=='session_changed' and prepares==1,'cancelled session reused preparation')
prepares=0;mode,calls,alive='ok',0,true
assert(Remote.complete(client,source,options))
assert(prepares==2 and calls==1,'remote image was not prepared again after download')
Resources.prepare=original_prepare
print('PASS: bounded native chapter remote images, authorization isolation and cancellation')
