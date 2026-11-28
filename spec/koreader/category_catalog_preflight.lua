require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-public-category-probe.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local root=assert(arg[1]);package.path=root..'/?.lua;'..package.path
local json=require('json')
local payload=assert(io.stdin:read(4*1024*1024+1));assert(#payload<=4*1024*1024)
local input=json.decode(payload)
local Catalog=require('weread.lib.category_catalog')
local output={model=Catalog.project(input.source,input.now)}
if input.native_http then
    local Client=require('weread.lib.client')
    local calls=0
    local client=Client:new({get=function(_self,_key,default) return default end})
    local request=client.request
    client.request=function(self,options)
        calls=calls+1
        assert(calls==1 and options.url=='https://weread.qq.com/web/categories?rank=1&synckey=0'
            and options.method=='GET' and options.skip_cookie==true and not options.body)
        return request(self,options)
    end
    output.native=Catalog.project(client:get_store_categories(),input.now);output.requests=calls
end
io.write('\nWEREAD_CATEGORY_RESULT='..json.encode(output))
