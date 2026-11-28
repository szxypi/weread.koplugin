-- A small cache of prepared thumbnails. Each caller owns its own copy, since
-- ImageWidget frees disposable buffers when the view closes.
local Cache = {}
Cache.__index = Cache

local MAX_BYTES = 6 * 1024 * 1024
local MAX_FILE_BYTES = 3 * 1024 * 1024
local MAX_SNAPSHOT_BYTES = 512 * 1024

local function fingerprint(path, capture)
    if type(path) ~= "string" or not path:match("%.thumb%.png$") then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_hash, hashoir = pcall(require, "ffi/hashoir")
    if not ok_lfs or not ok_hash then return nil end
    local before = lfs.symlinkattributes(path)
    if not before or before.mode ~= "file" or before.size > MAX_FILE_BYTES then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local hash
    local ok, digest, snapshot = pcall(function()
        hash = hashoir:new()
        local size, bytes = 0, nil
        local keep = capture and before.size > 0 and before.size <= MAX_SNAPSHOT_BYTES
        while true do
            local chunk, err = file:read(keep and before.size + 1 or 65536)
            if err then return nil end
            if not chunk then break end
            size = size + #chunk
            if size > MAX_FILE_BYTES then return nil end
            hash:update(chunk, #chunk)
            if keep then bytes = chunk; break end
        end
        local after = lfs.symlinkattributes(path)
        if not after or after.mode ~= "file" or size ~= before.size or size ~= after.size
            or before.ino ~= after.ino or before.dev ~= after.dev
            or before.modification ~= after.modification or before.change ~= after.change then
            return nil
        end
        return hash:hexdigest(), bytes
    end)
    local closed = file:close()
    if hash then pcall(hash.free, hash) end
    if ok and closed then return digest, snapshot end
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

function Cache:render(path, width, height, fit, loader, load_snapshot)
    local key = type(path) == "string" and type(fit) == "string"
        and path .. "\0" .. tostring(width) .. "\0" .. tostring(height) .. "\0" .. fit
    local capture = load_snapshot and key and not self.entries[key]
    local ok, digest, snapshot = pcall(self.fingerprint, path, capture)
    if not ok then digest = nil end
    -- A changed or unreadable file must invalidate every prepared size.
    for cached_key, entry in pairs(self.entries) do
        if entry.path == path and (not digest or entry.digest ~= digest) then self:_remove(cached_key) end
    end
    if not digest or not key then return loader() end
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
    local from_snapshot = snapshot and load_snapshot
    local buffer
    if from_snapshot then buffer = from_snapshot(snapshot)
    else buffer = loader() end
    if not buffer then return nil end
    local sized, bytes = pcall(function() return tonumber(buffer.stride) * tonumber(buffer.h) end)
    if not sized or not bytes or bytes <= 0 or bytes > self.max_bytes then return buffer end
    -- Snapshot decoding used the same bytes as the digest. A separate file
    -- decode still needs a second fingerprint to rule out a replacement.
    if not from_snapshot then
        local verified, current = pcall(self.fingerprint, path)
        if not verified or current ~= digest then return buffer end
    end
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
