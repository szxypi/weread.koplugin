-- A small cache of prepared thumbnails. Each caller owns its own copy, since
-- ImageWidget frees disposable buffers when the view closes.
local Cache = {}
Cache.__index = Cache

local MAX_BYTES = 6 * 1024 * 1024
local MAX_FILE_BYTES = 3 * 1024 * 1024

local function fingerprint(path)
    if type(path) ~= "string" or not path:match("%.thumb%.png$") then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_hash, hashoir = pcall(require, "ffi/hashoir")
    if not ok_lfs or not ok_hash then return nil end
    local before = lfs.symlinkattributes(path)
    if not before or before.mode ~= "file" or before.size > MAX_FILE_BYTES then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local hash
    local ok, result = pcall(function()
        hash = hashoir:new()
        local size = 0
        while true do
            local chunk = file:read(65536)
            if not chunk then break end
            size = size + #chunk
            if size > MAX_FILE_BYTES then return nil end
            hash:update(chunk, #chunk)
        end
        local after = lfs.symlinkattributes(path)
        if not after or after.mode ~= "file" or size ~= before.size or size ~= after.size
            or before.ino ~= after.ino or before.dev ~= after.dev
            or before.modification ~= after.modification or before.change ~= after.change then
            return nil
        end
        return hash:hexdigest()
    end)
    file:close()
    if hash then pcall(hash.free, hash) end
    return ok and result or nil
end

local function dispose(buffer)
    if buffer then pcall(function() buffer:free() end) end
end

function Cache.new(options)
    options = options or {}
    return setmetatable({ entries = {}, bytes = 0, clock = 0,
        max_bytes = options.max_bytes or MAX_BYTES,
        fingerprint = options.fingerprint or fingerprint }, Cache)
end

function Cache:_remove(key)
    local entry = self.entries[key]
    if not entry then return end
    self.entries[key] = nil
    self.bytes = self.bytes - entry.bytes
    dispose(entry.buffer)
end

function Cache:clear()
    for key in pairs(self.entries) do self:_remove(key) end
end

function Cache:render(path, width, height, fit, loader)
    local ok, digest = pcall(self.fingerprint, path)
    if not ok then digest = nil end
    -- A changed or unreadable file must invalidate every prepared size.
    for key, entry in pairs(self.entries) do
        if entry.path == path and (not digest or entry.digest ~= digest) then self:_remove(key) end
    end
    if not digest then return loader() end
    local key = path .. "\0" .. tostring(width) .. "\0" .. tostring(height) .. "\0" .. fit
    local entry = self.entries[key]
    if entry then
        local copied, buffer = pcall(function() return entry.buffer:copy() end)
        if copied and buffer then
            self.clock = self.clock + 1
            entry.used = self.clock
            return buffer
        end
        self:_remove(key)
    end
    local buffer = loader()
    if not buffer then return nil end
    local sized, bytes = pcall(function() return tonumber(buffer.stride) * tonumber(buffer.h) end)
    if not sized or not bytes or bytes <= 0 or bytes > self.max_bytes then return buffer end
    local verified, current = pcall(self.fingerprint, path)
    if not verified or current ~= digest then return buffer end
    local copied, saved = pcall(function() return buffer:copy() end)
    if not copied or not saved then return buffer end
    while self.bytes + bytes > self.max_bytes do
        local oldest_key, oldest
        for candidate, item in pairs(self.entries) do
            if not oldest or item.used < oldest then oldest_key, oldest = candidate, item.used end
        end
        if not oldest_key then break end
        self:_remove(oldest_key)
    end
    self.clock = self.clock + 1
    self.entries[key] = { path = path, digest = digest, buffer = saved, bytes = bytes, used = self.clock }
    self.bytes = self.bytes + bytes
    return buffer
end

local shared
return {
    new = Cache.new,
    shared = function()
        if not shared then shared = Cache.new() end
        return shared
    end,
    clear = function() if shared then shared:clear() end end,
}
