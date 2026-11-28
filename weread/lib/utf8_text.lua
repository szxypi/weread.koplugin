local M = {}

local function continuation(byte)
    return byte and byte >= 0x80 and byte <= 0xbf
end

-- Check the entire string without building a prefix. Callers can allow
-- specific ASCII controls such as tabs or line breaks in body text.
function M.valid(value, max_bytes, allow_empty, allowed_controls)
    if type(value) ~= "string" or not allow_empty and value == "" or #value > max_bytes then return false end
    local position, size = 1, #value
    while position <= size do
        local lead = value:byte(position)
        if lead < 0x80 then
            if lead == 0x7f or lead < 0x20 and not (allowed_controls and allowed_controls[lead]) then return false end
            position = position + 1
        else
            local second = value:byte(position + 1)
            if lead < 0xc2 or lead > 0xf4 or not continuation(second) then return false end
            if lead < 0xe0 then
                position = position + 2
            elseif lead < 0xf0 then
                -- Reject overlong encodings and UTF-16 surrogates.
                if not continuation(value:byte(position + 2))
                    or lead == 0xe0 and second < 0xa0 or lead == 0xed and second >= 0xa0 then return false end
                position = position + 3
            else
                -- Four-byte scalars run from U+10000 through U+10FFFF.
                if not continuation(value:byte(position + 2)) or not continuation(value:byte(position + 3))
                    or lead == 0xf0 and second < 0x90 or lead == 0xf4 and second >= 0x90 then return false end
                position = position + 4
            end
        end
    end
    return true
end

return M
