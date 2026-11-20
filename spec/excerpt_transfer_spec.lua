-- Fast offline lifecycle and HTTP-boundary tests with fake sockets.
package.path='./?.lua;./?/init.lua;'..package.path
local clock=1000
local listener
package.preload.socket=function()
    return {gettime=function() return clock end,bind=function(address,port)
        assert(address=='127.0.0.1' and port==0)
        listener={queue={},closed=false}
        function listener:settimeout(value) assert(value==0) end
        function listener:getsockname() return address,12345 end
        function listener:accept() return table.remove(self.queue,1) end
        function listener:close() self.closed=true end
        return listener
    end}
end
local Transfer=require('weread.lib.excerpt_transfer')
local png='\137PNG\r\n\26\n'..string.rep('p',70000)
local function connection(request)
    local client={request=request,output='',closed=false}
    function client:settimeout(value) assert(value==0) end
    function client:receive(limit)
        if #self.request==0 then return nil,'timeout','' end
        local chunk=self.request:sub(1,limit);self.request=self.request:sub(#chunk+1)
        return nil,'timeout',chunk
    end
    function client:send(data,first,last)
        -- Model a constrained nonblocking connection: LuaSocket reports the
        -- last byte written, even when it also reports a timeout.
        local sent=math.min(last,first+4095)
        self.output=self.output..data:sub(first,sent)
        if sent<last then return nil,'timeout',sent end
        return sent
    end
    function client:close() self.closed=true end
    return client
end
local released=0
local server=assert(Transfer.start(png,{address='127.0.0.1',allow_loopback=true,
    firewall=function(port,tag)
        assert(port==12345 and #tag==16 and tag:match('^[a-f0-9]+$'))
        return {release=function() released=released+1;return true end}
    end}))
local path=assert(server.url:match('^http://[^/]+(/.+)$'))
assert(path:match('^/[a-f0-9]+/$') and #path==34)
local function request(method,route)
    local client=connection(method..' '..route..' HTTP/1.1\r\nHost: local\r\n\r\n')
    listener.queue[#listener.queue+1]=client
    for _=1,100 do server:poll();if client.closed then return client.output end end
    error('response did not complete')
end
local body=request('GET',path..'card.png')
assert(body:find('200 OK',1,true) and body:sub(-#png)==png)
local head=request('HEAD',path..'card.png')
assert(head:find('Content-Length: '..#png,1,true) and not head:find(png,1,true))
assert(request('GET','/wrong'):find('404 Not Found',1,true))
assert(request('POST',path):find('405 Method Not Allowed',1,true))
local excessive=connection('GET / HTTP/1.1\r\n'..string.rep('a',8193))
listener.queue[#listener.queue+1]=excessive
for _=1,12 do server:poll() end
assert(excessive.closed and excessive.output=='','oversized header was served')
local clients={}
for index=1,5 do clients[index]=connection('');listener.queue[#listener.queue+1]=clients[index] end
server:poll();server:poll();assert(#server.clients==4 and clients[5].closed,'connection quota was bypassed')
clock=1121;server:poll()
for index=1,4 do assert(clients[index].closed,'idle connection did not expire') end
assert(server:stop() and server:stop() and released==1 and listener.closed and server.png==nil)
clock=1000
local another=assert(Transfer.start(png,{address='127.0.0.1',allow_loopback=true}))
clock=999;assert(not another:poll() and another.stopped,'backwards clock kept listener alive')
assert(not Transfer.start('bad',{address='127.0.0.1',allow_loopback=true}))
assert(not Transfer.start(png,{address='127.0.0.1',allow_loopback=true,
    firewall=function() error('synthetic error') end}) and listener.closed)
print('excerpt_transfer_spec: HTTP bounds, quotas and lifetime passed')
