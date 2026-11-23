-- Trim Unicode whitespace around a book search without changing its contents.
local spaces = {
    "\194\133", "\194\160", -- next line, no-break space
    "\225\154\128", -- ogham space mark
    "\226\128\128", "\226\128\129", "\226\128\130", "\226\128\131",
    "\226\128\132", "\226\128\133", "\226\128\134", "\226\128\135",
    "\226\128\136", "\226\128\137", "\226\128\138", "\226\128\168",
    "\226\128\169", "\226\128\175", "\226\129\159", "\227\128\128",
}

local function ascii_space(byte)
    return byte == 32 or (byte and byte >= 9 and byte <= 13)
end

local function space_length(value, position, remaining)
    if ascii_space(value:byte(position)) then return 1 end
    for _, space in ipairs(spaces) do
        if #space <= remaining and value:sub(position, position + #space - 1) == space then
            return #space
        end
    end
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    local first, last = 1, #value
    while first <= last do
        local length = space_length(value, first, last - first + 1)
        if not length then break end
        first = first + length
    end
    while first <= last do
        if ascii_space(value:byte(last)) then
            last = last - 1
        else
            local found = false
            for _, space in ipairs(spaces) do
                if last - #space + 1 >= first and value:sub(last - #space + 1, last) == space then
                    last = last - #space
                    found = true
                    break
                end
            end
            if not found then break end
        end
    end
    return value:sub(first, last)
end

-- Split on the same Unicode whitespace accepted by trim. Preserve all other
-- bytes so malformed text and literal punctuation remain literal searches.
local function words(value)
    if type(value) ~= "string" then return {} end
    local result, first, position = {}, nil, 1
    while position <= #value do
        local length = space_length(value, position, #value - position + 1)
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
