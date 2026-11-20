-- Reading timestamps may come from older caches or external shelf responses.
local M = {}
local MAX_TIMESTAMP = 253402300799 -- Last second of year 9999, UTC.

function M.value(value)
    local n = tonumber(value)
    if not n or n ~= n or n < 1 or n > MAX_TIMESTAMP then return nil end
    return math.floor(n)
end

function M.date(value)
    local timestamp = M.value(value)
    if not timestamp then return nil end
    -- Some devices cannot represent dates that other Lua runtimes accept.
    local ok, result = pcall(os.date, "%Y-%m-%d", timestamp)
    if not ok or type(result) ~= "string" or not result:match("^%d%d%d%d%-%d%d%-%d%d$") then return nil end
    return result
end

return M
