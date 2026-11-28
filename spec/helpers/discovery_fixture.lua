-- Scheduling stays observable; only the child-process boundary is synchronous.
local M = {}
function M.attach(host, enabled)
    host.discovery_worker = {
        start = function(_self, task, callback) callback(task()); return true end,
        cancel = function() end,
    }
    host.category_catalog_worker=host.discovery_worker
    host.category_catalog_store={read=function(self) return self.value end,write=function(self,value) self.value=value;return true end}
    host.showBusy=host.showBusy or function(self) self.busy_message={} end
    host.closeBusy=host.closeBusy or function(self) self.busy_message=nil end
    host.showTransientInfo=host.showTransientInfo or function(self,value) if self.showInfo then self:showInfo(value) end end
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
