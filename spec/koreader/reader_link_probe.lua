-- Real response metadata travels through memory pipes only, never files.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-link-probe-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(12*1024*1024+1)
local ok,result=pcall(function()
    assert(#bytes<=12*1024*1024)
    local input=json.decode(bytes);bytes=nil
    assert(type(input.samples)=='table' and #input.samples>=1 and #input.samples<=2)
    local Link=require('weread.lib.reader_link')
    local output={model=json.decode('[]')}
    local allowed={}
    for _,sample in ipairs(input.samples) do
        output.model[#output.model+1]=Link.project(sample.url,sample.html,json.decode)
        allowed[assert(Link.canonical(sample.url))]=true
    end
    if input.session then
        local scope={vid=input.session.vid,epoch=1}
        local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end,
            get=function(_self,key,default) if key=='cookies' then return input.session.cookies end;return default end}
        local client=require('weread.lib.client'):new(settings)
        local request,reads=client.request,0
        function client:request(options)
            assert(options.method=='GET' and allowed[options.url] and options.skip_cookie and options.persist_response_cookies==false)
            reads=reads+1;assert(reads<=#input.samples)
            return request(self,options)
        end
        output.native=json.decode('[]')
        for _,sample in ipairs(input.samples) do output.native[#output.native+1]=Link.fetch(client,sample.url) end
        output.requests=reads
    end
    return output
end)
io.stdout:write('\nWEREAD_LINK_RESULT='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
