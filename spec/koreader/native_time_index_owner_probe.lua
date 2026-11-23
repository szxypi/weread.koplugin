-- Read-only live source/index check. The caller sends credentials and source
-- digest through stdin; neither credentials nor source text are emitted.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local scope={vid=input.vid,epoch=1}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end,
    get=function(_,key,default) if key=='cookies' then return input.cookies end return default end}
local client=require('weread.lib.client'):new(settings);local request=client.request
client.request=function(self,options)
    assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
    local web='https://weread.qq.com';local url=options.url
    if url==web..'/api/userInfo?userVid='..scope.vid then assert(options.method=='GET')
    elseif url==web..'/web/book/chapterInfos' then
        local body=json.decode(options.body);assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id)
        for key in pairs(body) do assert(key=='bookIds') end
    elseif url==require('weread.lib.protocol').reader_url(input.book_id,input.uid) then assert(options.method=='GET')
    elseif url==web..'/web/book/chapter/e_0' or url==web..'/web/book/chapter/e_1' or url==web..'/web/book/chapter/e_3' then
        local body=json.decode(options.body);local protocol=require('weread.lib.protocol')
        assert(options.method=='POST' and body.b==protocol.e(input.book_id) and body.c==protocol.e(input.uid)
            and body.sc==1 and body.prevChapter==false and body.st==0)
        local allowed={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
        local count=0;for key in pairs(body) do assert(allowed[key]);count=count+1 end;assert(count==10)
    else error('outside_read_scope') end
    return request(self,options)
end
local Current=require('weread.lib.source_currentness');local selected=assert(Current.capture(settings))
local expected={book_id=input.book_id,chapter_uid=input.uid,raw_sha256=input.source_sha256,raw_bytes=input.source_bytes}
local checks=0
local ok,result=pcall(Current.fetch_resolving_index,client,expected,selected,{verify_catalog=function(catalog)
    checks=checks+1;assert(require('weread.lib.readtime_source').version(catalog,input.book_id)==input.version)
end})
local valid=ok and type(result)=='table' and type(result.chapter_idx)=='number'
    and result.chapter_idx%1==0 and result.chapter_idx>=0 and result.chapter_idx<=1000000
    and result.raw_sha256==input.source_sha256 and result.raw_bytes==input.source_bytes
    and result.source_current==true and result.upload_verified==false and checks==2
io.stdout:write('\nWEREAD_TIME_INDEX_OWNER='..json.encode{ok=valid==true,version_checked_twice=checks==2}..'\n')
