-- One owner-scoped latest-article GET; private input stays in the pipe.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-mp-latest-probe.lua')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json');local bytes=io.stdin:read(65537)
local ok,result=pcall(function()
    assert(#bytes<=65536)
    local input=json.decode(bytes);bytes=nil
    local web={web={cookies=input.cookies}}
    package.preload['weread.lib.read_access']=function() return {capture=function() return web end,
        matches=function(_settings,value) return value==web end} end
    local settings={get=function(_self,_key,default) return default end}
    local client=require('weread.lib.client'):new(settings)
    local Model=require('weread.lib.mp_catalog');local capture=assert(Model.capture(settings,{book_id=input.latest.bookId}))
    local request,requests=client.request,0
    function client:request(options)
        assert(options.url=='https://weread.qq.com/api/mp/cover?bookId='..input.latest.bookId and options.method=='GET'
            and options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        requests=requests+1;assert(requests==1)
        return request(self,options)
    end
    local result=Model.read_latest(client,capture)
    assert(result.ok and #result.articles==1 and result.articles[1].reviewId==input.latest.reviewId
        and result.articles[1].title==input.latest.title and result.articles[1].bookId==input.latest.bookId)
    return {matches=true,requests=requests}
end)
io.stdout:write('\nWEREAD_MP_LATEST_RESULT='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
