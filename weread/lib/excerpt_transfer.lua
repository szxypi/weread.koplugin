-- Temporary, bounded LAN transfer for an in-memory excerpt card.
-- The listener accepts only a fresh unguessable URL and lives for three minutes.
local socket = require('socket')
local M = {}

local function close(s) if s then pcall(s.close, s) end end
local function random_hex(n)
    local f = io.open('/dev/urandom', 'rb')
    if not f then return nil end
    local raw = f:read(n); f:close()
    if not raw or #raw ~= n then return nil end
    return (raw:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end
local function valid_ip(ip, allow_loopback)
    if type(ip) ~= 'string' then return false end
    local a,b,c,d = ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    a,b,c,d = tonumber(a),tonumber(b),tonumber(c),tonumber(d)
    return a and b and c and d and a > 0 and a < 224 and b < 256 and c < 256 and d < 256
        and (allow_loopback or a ~= 127) or false
end
local function interface_ip()
    local ok, result = pcall(function()
        local ffi = require('ffi'); require('ffi/posix_h')
        local network = require('ui/network/manager')
        if type(network.interface) ~= 'string' then return nil end
        local list = ffi.new('struct ifaddrs *[1]')
        if ffi.C.getifaddrs(list) ~= 0 then return nil end
        local current, found = list[0], nil
        while current ~= nil do
            if current.ifa_addr ~= nil and current.ifa_name ~= nil
                and ffi.string(current.ifa_name) == network.interface
                and current.ifa_addr.sa_family == ffi.C.AF_INET then
                local buf = ffi.new('char[?]', ffi.C.NI_MAXHOST)
                if ffi.C.getnameinfo(current.ifa_addr, ffi.sizeof('struct sockaddr_in'), buf,
                    ffi.C.NI_MAXHOST, nil, 0, ffi.C.NI_NUMERICHOST) == 0 then
                    local ip = ffi.string(buf)
                    if valid_ip(ip) then found = ip; break end
                end
            end
            current = current.ifa_next
        end
        ffi.C.freeifaddrs(list[0]); return found
    end)
    if ok and result then return result end
    local udp = socket.udp()
    if not udp then return nil end
    udp:settimeout(0)
    local connected = udp:setpeername('1.1.1.1', 53)
    local ip = connected and udp:getsockname() or nil
    close(udp)
    return valid_ip(ip) and ip or nil
end
local function response(status, content_type, body, head)
    local header = 'HTTP/1.1 '..status..'\r\nContent-Type: '..content_type
        ..'\r\nContent-Length: '..#body..'\r\nCache-Control: no-store\r\n'
        .."Content-Security-Policy: default-src 'none'; img-src 'self'; style-src 'unsafe-inline'\r\n"
        ..'X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n'
    return header, head and '' or body
end
function M.start(png, options)
    options = options or {}
    if type(png) ~= 'string' or #png < 8 or #png > 32*1024*1024
        or png:sub(1,8) ~= '\137PNG\r\n\26\n' then return nil, 'invalid_image' end
    local ip = options.address or interface_ip()
    if not valid_ip(ip, options.allow_loopback == true) then return nil, 'no_wifi' end
    local token = random_hex(16)
    local tag = random_hex(8)
    if not token or not tag then return nil, 'random_unavailable' end
    local listener = socket.bind(ip, 0)
    if not listener then return nil, 'listen_failed' end
    listener:settimeout(0)
    local _,port = listener:getsockname()
    local firewall
    if options.firewall then
        local ok
        ok, firewall = pcall(options.firewall, port, tag)
        if not ok or not firewall then close(listener); return nil, 'firewall_failed' end
    end
    local clock = options.clock or socket.gettime
    local start = clock()
    local state = {url='http://'..ip..':'..port..'/'..token..'/', clients={}, listener=listener,
        png=png, started=start, last=start, clock=clock, firewall=firewall, stopped=false}
    local image_path = '/'..token..'/card.png'
    local page = '<!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width,initial-scale=1">'
        ..'<meta charset="utf-8"><title>书摘卡片</title><p>长按图片保存到手机。</p><img style="max-width:100%" src="'..image_path..'">'
    function state:stop()
        if self.stopped then return self.cleanup_ok end
        self.stopped=true; close(self.listener); self.listener=nil
        for _,client in ipairs(self.clients) do close(client.socket) end
        self.clients={}; self.png=nil
        self.cleanup_ok = not self.firewall or self.firewall:release()
        return self.cleanup_ok
    end
    function state:poll()
        if self.stopped then return false end
        local now = self.clock()
        if now < self.last or now-self.started >= 180 then self:stop(); return false end
        self.last=now
        for _=1,4 do
            local conn = self.listener:accept()
            if not conn then break end
            conn:settimeout(0)
            if #self.clients >= 4 then close(conn)
            else self.clients[#self.clients+1]={socket=conn, data='', since=now} end
        end
        for i=#self.clients,1,-1 do
            local client=self.clients[i]; local done=false
            if now-client.since >= 120 then done=true
            elseif client.body == nil then
                local data,err,partial=client.socket:receive(1024)
                client.data=client.data..(data or partial or '')
                if #client.data > 8192 then done=true
                elseif client.data:find('\r\n\r\n',1,true) then
                    local method,path = client.data:match('^(%u+) ([^%s]+) HTTP/1%.[01]\r\n')
                    local status,kind,body='404 Not Found','text/plain','Not found'
                    if method ~= 'GET' and method ~= 'HEAD' then status,body='405 Method Not Allowed','Method not allowed'
                    elseif path == '/'..token..'/' then status,kind,body='200 OK','text/html; charset=utf-8',page
                    elseif path == image_path then status,kind,body='200 OK','image/png',self.png end
                    client.header,client.body=response(status,kind,body,method=='HEAD')
                    client.data=nil; client.offset=1
                elseif err and err ~= 'timeout' then done=true end
            else
                local data=client.header or client.body
                local last=math.min(#data, client.offset+32767)
                if client.offset <= #data then
                    local sent,err,partial=client.socket:send(data,client.offset,last)
                    client.offset=(sent or partial or client.offset-1)+1
                    if err and err~='timeout' then done=true end
                end
                if client.offset > #data then
                    if client.header then client.header=nil;client.offset=1 else done=true end
                end
            end
            if done then close(client.socket);table.remove(self.clients,i) end
        end
        return true
    end
    return state
end
return M
