-- Trim Unicode whitespace around a book search without changing its contents.
local spaces = {
    "\194\133", "\194\160", -- next line, no-break space
    "\225\154\128", -- ogham space mark
    "\226\128\128", "\226\128\129", "\226\128\130", "\226\128\131",
    "\226\128\132", "\226\128\133", "\226\128\134", "\226\128\135",
    "\226\128\136", "\226\128\137", "\226\128\138", "\226\128\168",
    "\226\128\169", "\226\128\175", "\226\129\159", "\227\128\128",
}
local space_width = {}
local width_by_start = {}
for _, space in ipairs(spaces) do
    space_width[space] = #space
    width_by_start[space:byte(1)] = #space
end

local function ascii_space(byte)
    return byte == 32 or (byte and byte >= 9 and byte <= 13)
end

local function space_length(value, position)
    local first = value:byte(position)
    if ascii_space(first) then return 1 end
    local width = width_by_start[first]
    if width then return space_width[value:sub(position, position + width - 1)] end
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    local first, last = 1, #value
    while first <= last do
        local length = space_length(value, first)
        if not length then break end
        first = first + length
    end
    while first <= last do
        local byte = value:byte(last)
        local width
        if ascii_space(byte) then
            width = 1
        elseif byte >= 128 and byte <= 191 then
            -- A trailing Unicode separator ends in a UTF-8 continuation byte.
            width = (last > first and space_width[value:sub(last - 1, last)])
                or (last - first >= 2 and space_width[value:sub(last - 2, last)])
        end
        if not width then break end
        last = last - width
    end
    return value:sub(first, last)
end

-- Split on the same Unicode whitespace accepted by trim. Preserve all other
-- bytes so malformed text and literal punctuation remain literal searches.
local function words(value)
    if type(value) ~= "string" then return {} end
    local result, first, position = {}, nil, 1
    while position <= #value do
        local length = space_length(value, position)
        if length then
            if first then result[#result + 1] = value:sub(first, position - 1); first = nil end
            position = position + length
        else
            first = first or position
            position = position + 1
        end
    end
    if first then result[#result + 1] = value:sub(first) end
    return result
end

return { trim = trim, words = words }
