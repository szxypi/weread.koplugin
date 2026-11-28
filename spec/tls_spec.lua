package.path = "./?.lua;" .. package.path
local TLS = require("weread.lib.tls")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local function matches(host, names, ips)
    return TLS.matches(host, {["2.5.29.17"]={dNSName=names,iPAddress=ips}})
end
expect(matches("weread.qq.com", {"weread.qq.com"}), "exact SAN")
expect(matches("WEREAD.qq.com", {"weread.QQ.com"}), "case insensitive")
expect(matches("i.weread.qq.com", {"*.weread.qq.com"}), "single wildcard label")
for _, host in ipairs({"weread.qq.com", "a.b.weread.qq.com", "weread.qq.com.evil.test", "evilweread.qq.com"}) do
    expect(not matches(host, {"*.weread.qq.com"}), "wildcard crossed a label")
end
for _, pattern in ipairs({"*read.qq.com", "weread.*.com", "*.com", "*", "weread.qq.com\0.evil", "weread..qq.com", "-weread.qq.com"}) do
    expect(not matches("weread.qq.com", {pattern}), "invalid DNS SAN matched")
end
expect(not TLS.matches("weread.qq.com", {}), "missing SAN must fail closed")
expect(not TLS.matches("weread.qq.com", {subject="weread.qq.com"}), "common name is not a SAN")
expect(not matches("127.0.0.1", {"127.0.0.1"}), "DNS SAN cannot authorize an IP")
expect(matches("127.0.0.1", {}, {"127.0.0.1"}), "IP SAN")
expect(not matches("127.0.0.2", {}, {"127.0.0.1"}), "wrong IP SAN")

local configured, closed, connected = nil, 0, 0
local connect_error=false
local names = {"weread.qq.com"}
package.preload["socket.url"] = function() return {parse=function() return {host="weread.qq.com"} end} end
package.preload["ssl.https"] = function()
    return {tcp=function(params)
        configured=params
        return function()
            return {sock={close=function() closed=closed+1 end},
                connect=function() connected=connected+1 if connect_error then error("synthetic-handshake-failure") end return 1 end,
                getpeercertificate=function() return {extensions=function() return {["2.5.29.17"]={dNSName=names}} end} end}
        end
    end}
end
local factory=TLS.create("https://weread.qq.com/path")
expect(configured.verify=="peer" and configured.cafile==TLS.ca_file, "CA verification policy")
expect(factory():connect("weread.qq.com",443)==1, "verified connection")
names={"example.invalid"}
local result,reason=factory():connect("weread.qq.com",443)
expect(not result and reason=="tls_hostname_mismatch" and closed==1, "hostname failure not closed")
result,reason=factory():connect("proxy.invalid",3128)
expect(not result and reason=="tls_proxy_not_supported" and connected==2 and closed==2, "proxy bypassed origin verification")
connect_error=true
result,reason=factory():connect("weread.qq.com",443)
expect(not result and reason=="tls_connect_failed" and closed==3,"failed handshake leaked a socket")
print("PASS: " .. checks .. " TLS certificate/SAN policy checks")
