-- Private stdin/stdout bridge. Python captures it; no credentials or bodies on disk.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-web-authorization-probe.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(131073)
local ok,result=pcall(function()
    assert(#bytes<=131072)
    local private=json.decode(bytes);bytes=nil
    local Auth=require('weread.lib.web_authorization')
    local input=Auth.snapshot(private,{vid=private.vid,epoch=1})
    local settings={get=function(_self,_key,default) return default end}
    local client=require('weread.lib.client'):new(settings)
    local request,posts,gets=client.request,0,0
    client.request=function(self,options)
        assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive,'unsafe request')
        if options.method=='POST' then
            assert(options.url=='https://weread.qq.com/web/login/renewal' and posts==0,'unexpected credential request')
            local body=json.decode(options.body)
            assert(body.rq=='%2Fweb%2Fbook%2Fread' and body.ql==false and not body.bookId,'unverified request body')
            posts=posts+1
        else
            assert(options.method=='GET' and (options.url=='https://weread.qq.com/web/shelf/sync'
                or options.url=='https://weread.qq.com/api/userInfo?userVid='..input.scope.vid),'unrelated request')
            gets=gets+1;assert(gets<=3,'verification replay')
        end
        return request(self,options)
    end
    local receipt=Auth.run(client,input)
    receipt.posts=posts;receipt.verification_reads=gets
    return receipt
end)
io.stdout:write('\nWEREAD_WEB_AUTH_PRIVATE='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
