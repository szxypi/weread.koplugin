-- One read-only native lookup, with private input confined to a memory pipe.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-mp-link-probe.lua')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(65537)
local ok,result=pcall(function()
    assert(#bytes<=65536)
    local input=json.decode(bytes);bytes=nil
    local selected={scope={vid=input.credentials.vid},credentials=input.credentials}
    package.preload['weread.lib.native_read_access']=function() return {
        capture=function() return selected end,matches=function(_settings,value) return value==selected end,
    } end
    local web={web={cookies=input.cookies}}
    package.preload['weread.lib.read_access']=function() return {
        capture=function() return web end,matches=function(_settings,value) return value==web end,
    } end
    local settings={get=function(_self,_key,default) return default end}
    local Model=require('weread.lib.mp_link')
    local capture=assert(Model.capture(settings,input.source))
    local client=require('weread.lib.client'):new(settings)
    local request,requests,web_requests=client.request,0,0
    function client:request(options)
        assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        if options.url=='https://i.weread.qq.com/mp/getreviewid' and options.method=='POST' then
            local body=json.decode(options.body)
            assert(#body.urls==1 and body.urls[1]==input.source)
            requests=requests+1;assert(requests==1)
        else
            assert(options.url=='https://weread.qq.com/web/mp/content?reviewId='..input.expected and options.method=='GET')
            web_requests=web_requests+1;assert(web_requests==1)
        end
        return request(self,options)
    end
    local found=Model.read(client,settings,capture)
    assert(found.ok and found.review_id==input.expected and found.book_id==input.expected:match('^(MP_WXS_%d+)_')
        and input.expected_title and found.title==input.expected_title)
    return {ok=true,native_requests=requests,web_requests=web_requests,title_matches=true}
end)
io.stdout:write('\nWEREAD_MP_LINK_RESULT='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
