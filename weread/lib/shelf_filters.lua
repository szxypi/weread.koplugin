local M = { KEY = 'shelf_filters_v1' }
local reading = { finished = true, unfinished = true, progress_zero = true, progress_active = true }
local download = { downloaded = true, not_downloaded = true }

function M.normalize(value)
    value = type(value) == 'table' and value or {}
    return {
        reading = reading[value.reading] and value.reading or nil,
        download = download[value.download] and value.download or nil,
    }
end

function M.same(a, b)
    if not a or not b then return a == b end
    return a.reading == b.reading and a.download == b.download
end

return M
