-- Personal statistics only travel through bounded captured memory pipes.
require("ffi").log=function() end
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("/tmp/weread-statistics-probe-settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
package.path=assert(arg[1]).."/?.lua;"..package.path
local json=require("json")
local raw=io.stdin:read(2*1024*1024+1)
local ok,result=pcall(function()
    assert(#raw<=2*1024*1024)
    local payload=json.decode(raw);raw=nil
    assert(type(payload.samples)=="table" and #payload.samples==5)
    local Data=require("weread.lib.statistics_data")
    local Source=require("weread.lib.statistics_source")
    local output={model=json.decode("[]")}
    for _,sample in ipairs(payload.samples) do
        output.model[#output.model+1]=Data.project(sample.source,sample.mode,sample.base_time,sample.now)
    end
    if payload.credentials then
        local scope={vid=payload.credentials.vid,epoch=1}
        local settings={get=function(_self,_key,default) return default end,
            get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
        local store={read=function() return payload.credentials,1 end}
        local client=require("weread.lib.client"):new(settings)
        local request,reads=client.request,0
        local allowed={}
        for _,sample in ipairs(payload.samples) do
            allowed["https://i.weread.qq.com/readdata/detail?baseTime="..sample.base_time.."&mode="..sample.mode]=true
        end
        function client:request(options)
            assert(options.method=="GET" and allowed[options.url],"statistics_readonly_scope_required")
            reads=reads+1;assert(reads<=5)
            return request(self,options)
        end
        local selected=assert(Source.capture(settings,store))
        output.native=json.decode("[]")
        for _,sample in ipairs(payload.samples) do
            local value=client:get_read_stats(sample.mode,sample.base_time,selected)
            assert(value._stats_source=="native");value._stats_source=nil
            output.native[#output.native+1]=value
        end
        output.requests=reads
    end
    return output
end)
io.stdout:write("\nWEREAD_STATISTICS_RESULT="..json.encode(ok and result or {error="statistics_probe_failed"}).."\n")
os.exit(ok and 0 or 1)
