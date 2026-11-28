-- Canonical decomposition using KOReader's bundled utf8proc. This module is
-- optional; callers retain the existing casefold-only fallback if unavailable.
local ffi=require('ffi')
require('ffi/utf8proc')
ffi.cdef[[
utf8proc_uint8_t *utf8proc_NFD(const utf8proc_uint8_t *);
int utf8proc_category(utf8proc_int32_t);
]]
local utf8proc=ffi.loadlib('utf8proc','3')
-- Resolve every native symbol up front so an older runtime falls back cleanly.
assert(utf8proc.utf8proc_category and utf8proc.utf8proc_NFD)
local free=ffi.C.free
local M={}

-- Variation selectors stay independent so searching an emoji without its
-- presentation selector does not lose the match.
function M.is_combining(cp)
    if type(cp)~='number' or cp<128 or cp>=0xFE00 and cp<=0xFE0F
        or cp>=0xE0100 and cp<=0xE01EF then return false end
    local value=utf8proc.utf8proc_category(cp)
    return value==6 or value==7 or value==8
end

function M.decompose(value)
    if type(value)~='string' or value:find('\0',1,true) then return nil end
    local pointer=utf8proc.utf8proc_NFD(value)
    if pointer==nil then return nil end
    local result=ffi.string(pointer)
    free(pointer)
    return result
end

return M
