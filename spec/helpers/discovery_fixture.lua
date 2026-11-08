-- Scheduling stays observable; only the child-process boundary is synchronous.
local M = {}
function M.attach(host, enabled)
    host.discovery_worker = {
        start = function(_self, task, callback) callback(task()); return true end,
        cancel = function() end,
    }
    host.settings = host.settings or { get = function(_self, key, default)
        if key == "api_key" and (not enabled or enabled()) then return "synthetic-key" end
        return default
    end }
    host.client.settings = host.settings
    if host.client.gateway then
        host.client.get_gateway_discovery = function(client, kind, options)
            return client:gateway(({ search = "/store/search", recommend = "/book/recommend", similar = "/book/similar" })[kind], {
                keyword = options.keyword, scope = kind == "search" and 10 or nil,
                bookId = options.book_id, sessionId = options.session_id, maxIdx = options.cursor, count = 20,
            })
        end
    end
end
return M
