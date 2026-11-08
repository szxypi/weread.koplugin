-- One bounded, read-only old-grant request. No refresh/login path is allowed.
require("ffi").log=function() end
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("/tmp/weread-native-expiry-probe-settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
package.path=assert(arg[1]).."/?.lua;"..package.path
local json=require("json")
local bytes=io.stdin:read(65537)
local ok,result=pcall(function()
    assert(#bytes<=65536)
    local payload=json.decode(bytes);bytes=nil
    local client=require("weread.lib.client"):new{get=function(_self,_key,default) return default end}
    local request,reads=client.request,0
    function client:request(options)
        assert(options.method=="GET" and options.url=="https://i.weread.qq.com/readdata/detail?baseTime=0&mode=monthly")
        reads=reads+1;assert(reads==1)
        return request(self,options)
    end
    local auth=require("weread.lib.native_authorization"):new(client,{expected_vid=payload.credentials.vid})
    local valid,error_code=pcall(auth.read_statistics,auth,payload.credentials,"monthly",0)
    auth:cancel()
    local expired=not valid and error_code=="native_auth/statistics/http_401"
    return {native_expired=expired,http_status=expired and 401 or valid and 200 or 0,requests=reads}
end)
io.stdout:write("\nWEREAD_NATIVE_EXPIRY_RESULT="..json.encode(ok and result or {error="native_expiry_probe_failed"}).."\n")
os.exit(ok and 0 or 1)
