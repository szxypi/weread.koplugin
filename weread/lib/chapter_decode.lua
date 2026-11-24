-- Decode the existing WeRead chapter payload without expanding the input into
-- a bit string or storing one Lua table entry per encoded character.
local M = {}
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local values = {}
for i = 1, #alphabet do values[alphabet:byte(i)] = i - 1 end
values[string.byte('-')], values[string.byte('_')] = 62, 63

function M.base64(data)
    local chunks, batch = {}, {}
    local a, b, c, count = 0, 0, 0, 0
    local function append(value)
        batch[#batch + 1] = value
        if #batch >= 1024 then chunks[#chunks + 1] = table.concat(batch);batch = {} end
    end
    for i = 1, #data do
        local value = values[data:byte(i)]
        if value then
            if count == 0 then a, count = value, 1
            elseif count == 1 then b, count = value, 2
            elseif count == 2 then c, count = value, 3
            else
                append(string.char(a * 4 + math.floor(b / 16), (b % 16) * 16 + math.floor(c / 4),
                    (c % 4) * 64 + value))
                count = 0
            end
        end
    end
    if count == 2 then append(string.char(a * 4 + math.floor(b / 16)))
    elseif count == 3 then append(string.char(a * 4 + math.floor(b / 16), (b % 16) * 16 + math.floor(c / 4))) end
    if #batch > 0 then chunks[#chunks + 1] = table.concat(batch) end
    return table.concat(chunks)
end

function M.swap_positions(encoded)
    local length = #encoded
    if length < 4 then return {} end
    if length < 11 then return {0, 2} end
    local n = math.min(4, math.floor((length + 9) / 10))
    local tmp = {}
    for i = length, length - n + 1, -1 do
        local byte = encoded:byte(i)
        local bin = {}
        repeat
            table.insert(bin, 1, tostring(byte % 2))
            byte = math.floor(byte / 2)
        until byte == 0
        local value = tonumber(table.concat(bin), 4) or 0
        table.insert(tmp, tostring(value))
    end
    tmp = table.concat(tmp)
    local result = {}
    local m = length - n - 2
    local step = #tostring(m)
    local i = 1
    while #result < 10 and i + step - 1 < #tmp do
        table.insert(result, (tonumber(tmp:sub(i, i + step - 1)) or 0) % m)
        local end2 = math.min(i + step, #tmp)
        if i + 1 <= #tmp then table.insert(result, (tonumber(tmp:sub(i + 1, end2)) or 0) % m) end
        i = i + step
    end
    return result
end

function M.reverse_swaps(encoded, positions)
    if #positions == 0 then return encoded end
    local changed = {}
    local function at(index)
        return changed[index] or encoded:sub(index, index)
    end
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            local left, right = positions[i] + k + 1, positions[i - 1] + k + 1
            changed[left], changed[right] = at(right), at(left)
        end
    end
    local indices = {}
    for index in pairs(changed) do indices[#indices + 1] = index end
    table.sort(indices)
    local parts, cursor = {}, 1
    for _, index in ipairs(indices) do
        if cursor < index then parts[#parts + 1] = encoded:sub(cursor, index - 1) end
        parts[#parts + 1] = changed[index]
        cursor = index + 1
    end
    if cursor <= #encoded then parts[#parts + 1] = encoded:sub(cursor) end
    return table.concat(parts)
end

function M.decode_payload(body)
    if #body == 0 then return "" end
    local encoded = body:sub(2)
    return M.base64(M.reverse_swaps(encoded, M.swap_positions(encoded)))
end

return M
