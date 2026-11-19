-- View-only stable ordering of validated personal-note snapshots.
local M = {}
local modes = {original=true, newest=true, oldest=true, chapter=true}
local function key(row, mode)
    local value
    if mode == 'chapter' then value = row.chapterIdx else value = row.createTime end
    local minimum = mode == 'chapter' and 0 or 1
    local maximum = mode == 'chapter' and 2147483647 or 4102444800
    if type(value) == 'number' and value == value and value % 1 == 0 and value >= minimum and value <= maximum then
        return value
    end
end
function M.rows(rows, mode)
    assert(type(rows) == 'table' and modes[mode], 'personal_notes_order/invalid')
    local entries = {}
    for index, row in ipairs(rows) do entries[#entries + 1] = {row = row, index = index, value = key(row, mode)} end
    if mode ~= 'original' then
        table.sort(entries, function(a, b)
            if a.value == b.value then return a.index < b.index end
            if a.value == nil then return false end
            if b.value == nil then return true end
            if mode == 'newest' then return a.value > b.value end
            return a.value < b.value
        end)
    end
    local result = {}
    for index, entry in ipairs(entries) do result[index] = entry.row end
    return result
end
return M
