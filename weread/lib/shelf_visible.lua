-- Find visible continuous-list rows using their immutable bottom offsets.
local M = {}

function M.first(bottoms, top)
    local low, high = 1, #bottoms
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if bottoms[mid] <= top then low = mid + 1 else high = mid - 1 end
    end
    return low
end

function M.books(source, bottoms, top, height)
    local result, index = {}, M.first(bottoms, top)
    local y = index > 1 and bottoms[index - 1] + 1 or 0
    while index <= #bottoms and y < top + height do
        if bottoms[index] > top then result[#result + 1] = source[index] end
        y = bottoms[index] + 1
        index = index + 1
    end
    return result
end

return M
