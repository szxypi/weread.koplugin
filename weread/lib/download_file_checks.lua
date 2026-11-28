local M = {}
local MAX_PROOFS = 512

local function same(a, b)
    return a and b and a.mode == "file" and b.mode == "file"
        and a.dev == b.dev and a.ino == b.ino and a.size == b.size
        and a.modification == b.modification and a.change == b.change
end

-- One synchronous validation pass over the book workspace. The downloader
-- holds its book lease and treats resource files as read-only during the pass.
-- Every later pass starts fresh, including after resume, repair and packaging.
function M.memoize(inspect)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    if not ok or not lfs.symlinkattributes then return inspect end
    local proofs, count = {}, 0
    return function(path)
        local parent = path:match("^(.*)/[^/]+$")
        local before = parent and lfs.symlinkattributes(parent, "mode") == "directory" and lfs.symlinkattributes(path)
        local proof = proofs[path]
        if proof then
            if same(proof.info, before) then return proof.size, proof.digest end
            proofs[path], count = nil, count - 1
        end
        if not before or before.mode ~= "file" then return end
        if not (before.dev and before.ino and before.size and before.modification and before.change) then
            return inspect(path)
        end
        local size, digest = inspect(path)
        if not size or not digest or not same(before, lfs.symlinkattributes(path)) then return end
        if count < MAX_PROOFS then
            proofs[path] = { info = before, size = size, digest = digest }
            count = count + 1
        end
        return size, digest
    end
end

return M
