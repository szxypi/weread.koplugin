-- A saved-session caller sends credentials and the expected hash via stdin.
-- Only a fixed result crosses stdout; neither the name nor credentials do.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-profile-account-probe.lua')
local Device=require('device')
require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local input=assert(json.decode(assert(io.stdin:read(65537))))
assert(type(input)=='table' and type(input.cookies)=='table' and type(input.owner)=='string'
    and type(input.name_hash)=='string' and #input.name_hash==64)
local scope={vid=input.owner,epoch=1}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return true end,
    get=function(_self,key,default)
        if key=='cookies' then return input.cookies end
        if key=='account' then return {user_vid=input.owner} end
        return default
    end}
local client=require('weread.lib.client'):new(settings)
local request=client.request;local reads=0
function client:request(options)
    assert(options.method=='GET' and options.url=='https://weread.qq.com/api/userInfo?userVid='
        ..require('weread.lib.protocol').urlencode(input.owner))
    reads=reads+1;assert(reads==1)
    return request(self,options)
end
local Account=require('weread.lib.profile_account')
local access=Account.capture(settings)
if not access then io.stdout:write('PROFILE_ACCOUNT_ACCESS_FAILED\n');os.exit(1) end
local name=Account.fetch(client,access)
if not name then io.stdout:write('PROFILE_ACCOUNT_FETCH_FAILED\n');os.exit(1) end
if require('weread.lib.crypto').sha256_hex(name)~=input.name_hash then
    io.stdout:write('PROFILE_ACCOUNT_NAME_MISMATCH\n');os.exit(1)
end
io.stdout:write('PROFILE_ACCOUNT_LIVE_OK\n')
