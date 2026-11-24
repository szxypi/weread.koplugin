package.path = "./?.lua;./?/init.lua;" .. package.path

local Cache = require("weread.lib.shelf_cover_bitmap_cache")
local digest = { a = "one", b = "two", c = "three" }
local loads, freed, copies = 0, 0, 0
local function bitmap(size, bad_copy)
    return { stride = size, h = 1, free = function(self)
        assert(not self.freed, "buffer freed twice")
        self.freed = true
        freed = freed + 1
    end, copy = function(self)
        assert(not self.freed, "copied a freed buffer")
        if bad_copy then error("copy failed") end
        copies = copies + 1
        return bitmap(size)
    end }
end
local function loader(size, bad_copy)
    return function() loads = loads + 1; return bitmap(size, bad_copy) end
end
local cache = Cache.new{ max_bytes = 20, fingerprint = function(path) return digest[path] end }
local function render(path, width, fit, load)
    return cache:render(path, width or 1, 1, fit or "crop", load or loader(10))
end

local first = render("a")
local again = render("a")
assert(loads == 1 and copies == 2 and first ~= again and cache.bytes == 10)
first:free(); again:free()
render("b"):free()
render("a"):free() -- Make b the least recently used entry.
render("c"):free()
assert(cache.bytes == 20 and loads == 3)
render("b"):free()
assert(loads == 4, "the least recently used entry should have been evicted")
digest.b = "changed without a size or timestamp change"
render("b"):free()
assert(loads == 5, "changed file content must invalidate the prepared bitmap")
render("b", 2):free()
render("b", 2, "contain"):free()
assert(loads == 7, "size and fit must distinguish cached bitmaps")
digest.b = nil
render("b"):free()
assert(cache.bytes == 0, "unreadable files must evict every cached variant")
local size_before = cache.bytes
render("a", 1, "crop", loader(21)):free()
assert(cache.bytes == size_before, "oversized buffers must not enter the cache")
render("a", 1, "crop", loader(10, true)):free()
assert(cache.bytes == 0, "failed copies must not enter the cache")
assert(cache:render("a", 1, 1, "crop", function() return nil end) == nil)
render("a"):free()
local freed_before = freed
cache:clear(); cache:clear()
assert(cache.bytes == 0 and freed == freed_before + 1, "clear must free each cached bitmap once")

local changing = Cache.new{ fingerprint = (function()
    local calls = 0
    return function() calls = calls + 1; return tostring(calls) end
end)() }
local result = changing:render("a", 1, 1, "crop", loader(10))
result:free()
assert(changing.bytes == 0, "file changed during decoding must not be cached")
local broken = Cache.new{ fingerprint = function() error("unavailable") end }
broken:render("a", 1, 1, "crop", loader(10)):free()
assert(broken.bytes == 0, "fingerprint errors must fall back to normal rendering")
print("shelf cover bitmap cache: ok")
