-- Request-local TLS verification; never change KOReader's global TLS policy.
local M = {}
local source = debug.getinfo(1, "S").source
local root = source:match("^@(.*/)weread/lib/tls%.lua$") or "./"
M.ca_file = root .. "integrations/ssl/cacert.pem"

local function dns_name(value)
    if type(value) ~= "string" or #value == 0 or #value > 254 then return nil end
    value = value:lower():gsub("%.$", "")
    if value == "" then return nil end
    if value:find("[^a-z0-9.-]") or value:find("..", 1, true) then return nil end
    for label in value:gmatch("[^.]+") do
        if #label > 63 or not label:match("^[a-z0-9].*[a-z0-9]$") and not label:match("^[a-z0-9]$") then return nil end
    end
    if value:sub(1, 1) == "." then return nil end
    return value
end

function M.matches(host, extensions)
    if type(host) ~= "string" or type(extensions) ~= "table" then return false end
    local san = extensions["2.5.29.17"]
    if type(san) ~= "table" then return false end
    -- IP addresses require an IP SAN, never a DNS SAN or a common name.
    if host:find(":", 1, true) or host:match("^[%d.]+$") then
        for _, name in ipairs(type(san.iPAddress) == "table" and san.iPAddress or {}) do
            if type(name) == "string" and name:lower() == host:lower() then return true end
        end
        return false
    end
    host = dns_name(host)
    if not host then return false end
    for _, name in ipairs(type(san.dNSName) == "table" and san.dNSName or {}) do
        if dns_name(name) == host then return true end
        if type(name) == "string" and name:sub(1, 2) == "*." then
            local suffix = dns_name(name:sub(3))
            -- Only a complete left-most label may be a wildcard.
            local tail = host:match("^[^.]+%.(.+)$")
            if suffix and suffix:find(".", 1, true) and suffix == tail then return true end
        end
    end
    return false
end

function M.create(url)
    -- Load LuaSec only when a real HTTPS transport is created.
    local expected = require("socket.url").parse(url).host
    assert(type(expected) == "string" and expected ~= "", "tls_invalid_host")
    local factory = require("ssl.https").tcp{
        mode = "client", protocol = "any", verify = "peer", cafile = M.ca_file,
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
    }
    return function()
        local connection = factory()
        local connect = connection.connect
        function connection:connect(host, port)
            if type(host) ~= "string" or host:lower() ~= expected:lower() then
                self:close()
                return nil, "tls_proxy_not_supported"
            end
            local ok_connect, result, err = pcall(connect, self, host, port)
            if not ok_connect or not result then
                self:close()
                return nil, ok_connect and err or "tls_connect_failed"
            end
            local ok, matches = pcall(function()
                local certificate = self:getpeercertificate()
                return certificate and M.matches(expected, certificate:extensions())
            end)
            if not ok or not matches then
                self:close()
                return nil, "tls_hostname_mismatch"
            end
            return result
        end
        -- LuaSec forwards close only after its handshake. Provide it for the
        -- pre-handshake host guard too; failed handshakes are closed by HTTP.
        function connection:close() return self.sock:close() end
        return connection
    end
end

return M
