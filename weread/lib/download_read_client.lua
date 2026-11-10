-- A task-local client view for paced book-source reads. Construct this only
-- inside a background download task; the UI client is never modified.
local M = {}

local function source_read(options)
    if type(options) ~= 'table' or type(options.url) ~= 'string' then return false end
    local method = options.method or (options.body and 'POST' or 'GET')
    if method == 'GET' and not options.body then
        return options.url:match('^https://weread%.qq%.com/web/reader/[a-z0-9]+$') ~= nil
    end
    return method == 'POST' and type(options.body) == 'string'
        and options.url:match('^https://weread%.qq%.com/web/book/chapter/[et]_[0-3]$') ~= nil
end

function M.wrap(client, wait)
    assert(type(client) == 'table' and (wait == nil or type(wait) == 'function'))
    local proxy = setmetatable({}, { __index = client })
    function proxy:request(options)
        local paced = source_read(options)
        local body, code, headers, status = client:request(options)
        if paced then (wait or require('socket').sleep)(1) end
        return body, code, headers, status
    end
    return proxy
end

return M
