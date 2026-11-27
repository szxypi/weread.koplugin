package.path='./?.lua;'..package.path
local valid,mode,calls,closed=true,'ok',{},0
local Access=require('weread.lib.native_read_access')
local checks=0
Access.matches=function() checks=checks+1;return valid end
package.loaded['weread.lib.native_position_protocol']={credentials=function(c) return c.valid==true end,
    id=function(s) return type(s)=='string' and s:match('^[1-9]%d*$') and s or nil end}
package.loaded['weread.lib.native_authorization']={new=function(_self,_client,options)
    return {_request=function(_request_self,stage,url,body,credentials)
        assert(options.is_current() and credentials.vid=='123');calls[#calls+1]=stage
        if mode=='catalog429' then error('native_auth/chapter_info/http_429',0) end
        if mode=='info_transport' then error('native_auth/chapter_info/transport',0) end
        if mode=='rejected' then error('native_auth/chapter_info/rejected',0) end
        if stage=='chapter_info' then
            assert(url=='https://i.weread.qq.com/book/info?bookId=456' and body==nil)
            return {bookId='456',format='epub',version=mode=='version_changed' and 8 or 7}
        end
        assert(stage=='chapter_catalog' and url=='https://i.weread.qq.com/book/chapterInfos'
            and body.bookIds[1]=='456' and body.synckeys[1]==0)
        if mode=='catalog_timeout' then error('native_auth/chapter_catalog/timeout',0) end
        return {data={{bookId='456',updated={{chapterUid=7,wordCount=mode=='catalog_changed' and 101 or 100,price=mode=='paid' and 10 or 0,
            chapterIdx=mode=='bad_display' and 'invalid' or 1}}}}}
    end,cancel=function() closed=closed+1 end}
end}
package.loaded['weread.lib.native_chapter_archive']={read=function(data,envelope,vid,options)
    calls[#calls+1]='decode'
    assert(data=='synthetic-archive' and envelope=='synthetic-envelope' and vid=='123' and options.chapter_uid=='7')
    if mode=='decode_error' then error('private archive content') end
    return {body='body',css='css',assets={},is_text=false,image_signatures_recognized=true,unusable_resources=0}
end}
local client={request=function(_self,request)
    calls[#calls+1]='download'
    assert(request.method=='GET' and request.skip_cookie==true and request.persist_response_cookies==false
        and request.sensitive==true and request.headers.vid=='123')
    assert(request.url:find('chapters=0%%2C7') and request.url:find('stopAutoPayWhenBNE=1',1,true)
        and request.url:find('preview=0',1,true) and request.url:find('bookVersion=7',1,true))
    if mode=='429' then return nil,429,{} end
    if mode=='401' then return nil,401,{} end
    if mode=='download_transport' then return nil,nil,nil,'closed' end
    if mode=='download_thrown' then error('sensitive_request_failed',0) end
    if mode=='response_limit' then assert(not request.sink(string.rep('x',32*1024*1024+1)));return nil,nil end
    if mode=='changed' then valid=false end
    if mode=='large' then assert(not request.sink(string.rep('x',32*1024*1024+1)));return nil,200,{} end
    request.sink('synthetic-archive')
    if mode=='header' then return nil,200,{} end
    if mode=='duplicate_header' then return nil,200,{encryptkey='one',EncryptKey='two'} end
    return nil,200,{EncryptKey='synthetic-envelope'}
end}
local Source=require('weread.lib.native_chapter_source')
local selected={credentials={vid='123',valid=true},scope={vid='123'}}
local options={is_current=function() return true end}
local function run(next_mode)
    mode,calls,valid=next_mode,{},true
    return Source.fetch(client,{},selected,'456','7',options)
end
local value=assert(run('ok'))
assert(table.concat(calls,',')=='chapter_info,chapter_catalog,download,decode' and value.body=='body'
    and value.chapter_uid=='7' and value.book_version==7 and value.source_channel=='eink'
    and value.coordinate_source_authoritative==false and value.image_signatures_recognized==true)
local expected={book_version=value.book_version,reading_catalog_sha256=value.reading_catalog_sha256}
value=assert(run('bad_display'))
assert(value.body=='body' and #calls==4,'invalid display metadata blocked an otherwise valid chapter download')
for _,case in ipairs({{'paid','not_entitled',2},{'429','rate_limited',3},{'401','auth_expired',3},
    {'catalog429','rate_limited',1},{'rejected','service_rejected',1},{'info_transport','transport',1},
    {'catalog_timeout','transport',2},{'download_transport','transport',3},{'download_thrown','transport',3},
    {'response_limit','unavailable',3},
    {'header','unavailable',3},{'duplicate_header','unavailable',3},
    {'large','unavailable',3},{'decode_error','unavailable',4},{'changed','session_changed',3}}) do
    local result,reason=run(case[1]);assert(not result and reason==case[2] and #calls==case[3],case[1])
end
calls={};valid=false;local result,reason=Source.fetch(client,{},selected,'456','7',options)
assert(not result and reason=='session_changed' and #calls==0)
valid=true;result,reason=Source.fetch(client,{},selected,'456','9007199254740992',options)
assert(not result and reason=='invalid' and #calls==0)
assert(closed==17,'authorization not closed')
options.expected_catalog=expected
for _,change in ipairs({'version_changed','catalog_changed'}) do
    result,reason=run(change)
    assert(not result and reason=='catalog_changed' and #calls==2,'content requested after '..change)
end
assert(run('ok'))
options.expected_catalog=nil
local settings={}
checks=0;assert(run('ok'));local direct_checks=checks
local bound=assert(Access.guard(settings,options.is_current,selected))
checks=0;assert(Source.fetch(client,settings,selected,'456','7',{is_current=bound}))
assert(checks==direct_checks,'chapter request reread the grant through a shared guard')
local different={credentials=selected.credentials,scope=selected.scope}
checks=0;assert(Source.fetch(client,settings,different,'456','7',{is_current=bound}))
assert(checks==2*direct_checks,'chapter request inherited the guard for a different grant')
print('PASS: native chapter scope, entitlement, limited transport and source isolation')
