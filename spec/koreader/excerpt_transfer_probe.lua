-- Only synthetic images and loopback connections; no account or firewall access.
require('setupkoenv')
local root=assert(debug.getinfo(1,'S').source:match('^@(.+)/spec/koreader/[^/]+$'))
package.path=root..'/?.lua;'..package.path
local socket=require('socket')
local Transfer=require('weread.lib.excerpt_transfer')
local png='\137PNG\r\n\26\n'..string.rep('s',70000)
local now=1000
local state=assert(Transfer.start(png,{address='127.0.0.1',allow_loopback=true,clock=function() return now end}))
local port=assert(tonumber(state.url:match(':(%d+)/')))
local path=assert(state.url:match('^http://[^/]+(/.+)$'))
local function request(raw_request)
    local client=assert(socket.tcp());client:settimeout(1);assert(client:connect('127.0.0.1',port));client:settimeout(0)
    assert(client:send(raw_request));local out=''
    for _=1,1000 do
        state:poll()
        local data,err,partial=client:receive(65536)
        out=out..(data or partial or '')
        if err=='closed' then client:close();return out end
    end
    error('request did not complete')
end
local function get(route,method)
    return request((method or 'GET')..' '..route..' HTTP/1.1\r\nHost: local\r\n\r\n')
end
local page=get(path)
assert(page:find('200 OK',1,true) and page:find(path..'card.png',1,true))
local image=get(path..'card.png')
assert(image:find('Content-Length: '..#png,1,true) and image:sub(-#png)==png)
local head=get(path..'card.png','HEAD')
assert(head:find('Content-Length: '..#png,1,true) and not head:find(png,1,true))
assert(get('/wrong/card.png'):find('404 Not Found',1,true))
assert(get(path,'POST'):find('405 Method Not Allowed',1,true))
now=1180;assert(not state:poll() and state.stopped and state.png==nil)
local refused=assert(socket.tcp());refused:settimeout(.2);assert(not refused:connect('127.0.0.1',port));refused:close()
assert(not Transfer.start('bad',{address='127.0.0.1',allow_loopback=true}))
assert(not Transfer.start(png,{address='127.0.0.1',allow_loopback=true,
    firewall=function() error('synthetic firewall failure') end}),'firewall exception was not contained')
print('WEREAD_TRANSFER=PASS')
os.exit(0)
