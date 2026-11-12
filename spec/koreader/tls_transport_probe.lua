-- Synthetic/anonymous transport only. Never accepts credentials or headers.
require("ffi").log = function() end
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/tmp/weread-tls-probe-settings.lua")
package.path = assert(arg[1]) .. "/?.lua;" .. package.path
if arg[3] and arg[3] ~= "-" then require("weread.lib.tls").ca_file = arg[3] end
local client = require("weread.lib.client"):new({get=function(_self,_key,default) return default end})
local ok, body, code = pcall(client.request, client, {
    url=assert(arg[2]), skip_cookie=true, sensitive=true, diagnostic_api="tls_probe", timeout={3,3},
    headers={Authorization="Bearer synthetic-transport-sentinel"},
})
print(require("json").encode({ok=ok and code==200, code=code, bytes=ok and #body or 0}))
