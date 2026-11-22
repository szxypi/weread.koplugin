-- Exercise the real KOReader JSON decoder using synthetic input only.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local client=require('weread.lib.client'):new({get=function(_,_,default) return default end})
for line in io.stdin:lines() do
    local decoded=client:json_decode(line)
    print('WEREAD_JSON_UNICODE='..client:json_encode(decoded))
end
