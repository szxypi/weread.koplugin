package.path='./?.lua;'..package.path
local current=true
local source_calls,remote_calls=0,0
local selected={fingerprint=string.rep('a',64),renewal_pending=false}
local Access=require('weread.lib.native_read_access')
local captures=0
Access.capture=function() captures=captures+1;return selected end
Access.matches=function() return current end
local source={book_id='42',chapter_uid='37',book_version=1,catalog_sha256=string.rep('b',64),
    reading_catalog_sha256=string.rep('c',64),source_channel='eink',coordinate_source_authoritative=false,body='<p>Native</p>'}
local source_error,remote_error,change_source,change_remote,remote_missing
local received_catalog
package.loaded['weread.lib.native_chapter_source']={fetch=function(_,_,_,book,uid,options)
    source_calls=source_calls+1;assert(book=='42' and uid=='37' and options.is_current())
    received_catalog=options.expected_catalog
    if change_source then current=false end
    if source_error then return nil,source_error end
    return source
end}
package.loaded['weread.lib.native_chapter_remote']={complete=function(_,value,options)
    remote_calls=remote_calls+1;assert(value==source and options.is_current())
    if change_remote then current=false end
    if remote_error then return nil,remote_error end
    if remote_missing then assert(options.allow_missing_images==true) end
    return {xhtml='<p>Native</p>',css='raw-style',assets={{href='images/a.png',data='fixture'}},missing_images=remote_missing and 1 or nil,
        coordinate_source_authoritative=false}
end}
package.loaded['weread.lib.content']={sanitize_book_css=function(css) assert(css=='raw-style');return 'safe-style' end}
local Direct=require('weread.lib.native_direct_source')
local expected={book_id='42',chapter_uid='37',book_version=1,reading_catalog_sha256=string.rep('c',64),
    access_fingerprint=selected.fingerprint}
local options={is_current=function() return current end}
local function fetch() return Direct.fetch({}, {},'42','37',expected,options) end
local result=assert(fetch())
assert(result.xhtml=='<p>Native</p>' and result.css=='safe-style' and #result.assets==1
    and result.source_channel=='eink' and result.coordinate_source_authoritative==false and result.missing_images==0
    and result.source_raw==source.body and #result.source_sha256==64 and source_calls==1 and remote_calls==1)
local settings={}
local bound=assert(Access.guard(settings,options.is_current,selected))
local before_bound=captures
assert(Direct.fetch({},settings,'42','37',expected,{is_current=bound}))
assert(captures==before_bound,'direct source recaptured the same grant')
assert(Direct.fetch({}, {},'42','37',expected,{is_current=bound}))
assert(captures==before_bound+1,'direct source inherited a grant from different settings')
remote_missing=true
local missing=assert(Direct.fetch({}, {},'42','37',expected,{is_current=function() return true end,allow_missing_images=true}))
assert(missing.missing_images==1 and missing.xhtml:find('placeholders',1,true)
    and missing.xhtml:find('<p>Native</p>',1,true),'missing-image warning was not embedded')
remote_missing=nil
local remote_before_stale=remote_calls
source.is_text=true
local unsupported,format_error=fetch()
assert(not unsupported and format_error=='unsupported_format' and remote_calls==remote_before_stale)
source.is_text=false
local changed={};for key,value in pairs(expected) do changed[key]=value end
changed.reading_catalog_sha256=string.rep('d',64)
local value,reason=Direct.fetch({}, {},'42','37',changed,options)
assert(not value and reason=='catalog_changed' and remote_calls==remote_before_stale)
changed.reading_catalog_sha256=expected.reading_catalog_sha256;changed.book_version=2
value,reason=Direct.fetch({}, {},'42','37',changed,options)
assert(not value and reason=='catalog_changed' and remote_calls==remote_before_stale)
changed.book_version=1;changed.access_fingerprint=string.rep('f',64)
local before=source_calls
value,reason=Direct.fetch({}, {},'42','37',changed,options)
assert(not value and reason=='session_changed' and source_calls==before)
selected.renewal_pending=true;value,reason=fetch()
assert(not value and reason=='session_changed' and source_calls==before);selected.renewal_pending=false
for _,failure in ipairs({'not_entitled','auth_expired','rate_limited','service_rejected','transport'}) do
    source_error=failure;value,reason=fetch();assert(not value and reason==failure)
    assert(received_catalog==expected,'source request did not receive the expected catalog')
end
source_error=nil;remote_error='remote_unsupported';value,reason=fetch()
assert(not value and reason=='remote_unsupported');remote_error=nil
change_source=true;value,reason=fetch();assert(not value and reason=='session_changed')
change_source=false;current=true;change_remote=true;value,reason=fetch();assert(not value and reason=='session_changed')
change_remote=false;current=true
source.coordinate_source_authoritative=true;value,reason=fetch();assert(not value and reason=='invalid_source')
source.coordinate_source_authoritative=false
value,reason=Direct.fetch({}, {},'42','37',expected,{is_current=function() return false end})
assert(not value and reason=='session_changed')
changed.reading_catalog_sha256='bad';before=source_calls
value,reason=Direct.fetch({}, {},'42','37',changed,options)
assert(not value and reason=='invalid' and source_calls==before)
print('PASS: direct native chapter binds catalog and authorization without Web coordinates')
