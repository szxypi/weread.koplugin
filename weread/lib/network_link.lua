-- Optional read-only background jobs use a link check, never a UI DNS probe
-- on the production host. Older test hosts retain their existing interface.
local M = {}
function M.available(host)
    if type(host.isNetworkLinkAvailable)=='function' then return host:isNetworkLinkAvailable() end
    if type(host.isNetworkConnected)=='function' then return host:isNetworkConnected() end
    if type(host.isNetworkOnline)=='function' then return host:isNetworkOnline() end
    return true
end
return M
