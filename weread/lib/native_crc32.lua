-- CRC-32 of an extracted ZIP entry. The Lua implementation remains available
-- when the device does not expose a compatible zlib library.
local bit = require("bit")
local table32 = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        c = bit.bxor(bit.rshift(c, 1), bit.band(c, 1) == 1 and 0xedb88320 or 0)
    end
    table32[i] = c
end

local function fallback(data)
    local c = -1
    for i = 1, #data do
        c = bit.bxor(bit.rshift(c, 8), table32[bit.band(bit.bxor(c, data:byte(i)), 255)])
    end
    return bit.bnot(c)
end

local native
do
    local ok, result = pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[unsigned long crc32(unsigned long, const unsigned char *, unsigned int);]]
        local lib
        for _, name in ipairs({"z", "libz.so.1", "libz.so", "zlib1"}) do
            local loaded, candidate = pcall(ffi.load, name)
            if loaded then lib = candidate; break end
        end
        if not lib then return end
        local function calculate(data)
            return bit.tobit(tonumber(lib.crc32(0, data, #data)))
        end
        if calculate("") ~= 0 or calculate("123456789") ~= bit.tobit(0xcbf43926)
            or calculate("\0\255\128lua") ~= fallback("\0\255\128lua") then return end
        return calculate
    end)
    if ok then native = result end
end

return function(data)
    if native then
        local ok, result = pcall(native, data)
        if ok and type(result) == "number" then return result end
        native = nil
    end
    return fallback(data)
end
