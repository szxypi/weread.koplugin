-- Captured private pipe only, with optional explicit read-only native HTTPS.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local input=json.decode(io.read('*a'))
local Check=require('weread.lib.source_currentness')
local results=json.decode('[]')
local client,access
if input.native_http then
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open('/dev/shm/weread-currentness-probe-settings.lua')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local cookies=input.cookies
    local scope={vid=input.vid,epoch=1}
    local settings={get_auth_scope=function() return scope end,
        auth_scope_matches=function(_self,value) return value==scope end,get=function(_self,key,default)
        if key=='cookies' then return cookies end
        if key=='account' then return {user_vid=input.vid} end
        return default
    end}
    client=require('weread.lib.client'):new(settings);access=assert(Check.capture(settings))
end
local ok,reason=pcall(function()
    for _i,sample in ipairs(input.samples) do
        results[#results+1]=input.native_http and Check.fetch(client,sample.expected,access)
            or Check.project(sample.expected,sample.before,sample.reader,sample.raw,sample.after)
    end
end)
if not ok then
    local code=type(reason)=='string' and reason:match('^source_currentness/[a-z_]+$') or 'source_currentness/native_unverified'
    io.write('\nSOURCE_CURRENTNESS_RESULT=',json.encode{error=code,completed=#results})
    os.exit(1)
end
io.write('\nSOURCE_CURRENTNESS_RESULT=',json.encode(results))
