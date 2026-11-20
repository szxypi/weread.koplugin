-- Synthetic LAN fixture. The shared directory and payload contain no account data.
require('setupkoenv')
local source=assert(debug.getinfo(1,'S').source:match('^@(.+)/spec/koreader/[^/]+$'))
package.path=source..'/?.lua;'..package.path
local socket=require('socket')
local directory=assert(os.getenv('WEREAD_LAN_DIR'))
local interface=assert(os.getenv('WEREAD_LAN_INTERFACE'))
package.loaded['ui/network/manager']={interface=interface}
-- An interface address must work even when there is no default route.
socket.udp=function() error('unexpected route fallback') end
local png=assert(require('mime').unb64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aP8AAAAASUVORK5CYII='))
local server=assert(require('weread.lib.excerpt_transfer').start(png))
local f=assert(io.open(directory..'/url','w'));f:write(server.url);f:close()
local started=socket.gettime()
while socket.gettime()-started<45 do
    local stop=io.open(directory..'/stop','r')
    if stop then stop:close();break end
    assert(server:poll());socket.sleep(.01)
end
assert(server:stop())
print('WEREAD_LAN_SERVER=PASS')
os.exit(0)
