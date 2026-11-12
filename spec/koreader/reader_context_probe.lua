-- Real Reader payloads and session values stay in the private parent pipe.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-context-probe-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(12*1024*1024+1)
local ok,result=pcall(function()
    assert(#bytes<=12*1024*1024)
    local input=json.decode(bytes);bytes=nil
    assert(type(input.samples)=='table' and #input.samples>=1 and #input.samples<=2)
    local Context=require('weread.lib.reader_context')
    local output={model=json.decode('[]')}
    local allowed={}
    for _,sample in ipairs(input.samples) do
        output.model[#output.model+1]=Context.project(sample.book,sample.html,json.decode)
        assert(Context.url(sample.book)==sample.url);allowed[sample.url]=true
    end
    if input.session then
        local settings={get=function(_self,key,default) if key=='cookies' then return input.session.cookies end;return default end,
            merge_set_cookie=function() end}
        local client=require('weread.lib.client'):new(settings)
        local request,reads=client.request,0
        function client:request(options)
            assert(options.method=='GET' and allowed[options.url] and options.sensitive and options.diagnostic_api=='reader_context'
                and options.headers.Referer==options.url)
            reads=reads+1;assert(reads<=#input.samples)
            return request(self,options)
        end
        local get_text,native_html=client.get_text
        function client:get_text(...)
            native_html=get_text(self,...)
            return native_html
        end
        output.native=json.decode('[]')
        for _,sample in ipairs(input.samples) do
            local state=require('weread.lib.content').ensure_reader_state(client,sample.book)
            output.native[#output.native+1]={context=state,html=native_html}
        end
        output.requests=reads
    end
    return output
end)
io.stdout:write('\nWEREAD_CONTEXT_RESULT='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
