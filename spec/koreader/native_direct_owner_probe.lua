-- Real account input and temporary file path stay inside captured pipes/tmpfs.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,get=function(_,_,default) return default end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local original_capture=Access.capture
Access.capture=function(s,existing) return original_capture(s,existing or store) end
local selected=assert(Access.capture(settings));local client=require('weread.lib.client'):new(settings)
local request=client.request;local requests=0
client.request=function(self,options)
    requests=requests+1;assert(requests<=69 and options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    local url=options.url;local headers=options.headers or {};local base='https://i.weread.qq.com'
    if url==base..'/book/info?bookId='..input.book_id then assert(options.method=='GET')
    elseif url==base..'/book/chapterInfos' then
        assert(options.method=='POST');local body=json.decode(options.body)
        assert(#body.bookIds==1 and body.bookIds[1]==input.book_id and body.synckeys[1]==0
            and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
    elseif url:find(base..'/book/chapterdownload?',1,true)==1 then
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
            and url:find('chapters=0%2C'..input.uid..'&',1,true)
            and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
    else
        assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
            and not headers.vid and not headers.accessToken and not headers.Cookie)
    end
    if url:find(base,1,true)==1 then assert(headers.vid==input.credentials.vid and headers.accessToken==input.credentials.accessToken) end
    return request(self,options)
end
local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=scope.vid,
    is_current=function() return Access.matches(settings,selected) end})
local catalog=require('weread.lib.native_book_catalog').read(auth,input.credentials,input.book_id,'native_catalog')
auth:cancel();assert(catalog.version==input.book_version and catalog.reading_digest)
local chapter
for _,row in ipairs(catalog.reading_chapters) do
    if row.chapterUid==input.uid then assert(not chapter and row.downloadable);chapter=row end
end
assert(chapter)
local expected={book_id=input.book_id,chapter_uid=input.uid,book_version=catalog.version,
    reading_catalog_sha256=catalog.reading_digest,access_fingerprint=selected.fingerprint}
local book={book_id=input.book_id,title='Synthetic native book',author='Fixture'}
local target={chapterUid=input.uid,title='Synthetic chapter',chapterIdx=chapter.chapterIdx}
local result,reason=require('weread.lib.native_direct_reader').build(client,settings,book,target,expected,
    {is_current=function() return true end,allow_missing_images=true})
if not result then
    local allowed={not_entitled=true,auth_expired=true,rate_limited=true,service_rejected=true,session_changed=true,
        catalog_changed=true,unavailable=true,invalid_source=true,invalid_image=true,remote_unsupported=true,storage=true}
    print('WEREAD_DIRECT_OWNER='..json.encode{ok=false,reason=allowed[reason] and reason or 'unavailable',requests=requests})
    return
end
assert(result.source_sha256==input.source_sha256 and result.book_version==input.book_version and not result.reused)
assert(requests>=5 and require('weread.lib.native_direct_path').contains(settings,result.path))
print('WEREAD_DIRECT_OWNER='..json.encode{ok=true,path=result.path,requests=requests,source_matches=true,missing_images=result.missing_images})
