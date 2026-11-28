package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local files, directories, modified = {}, {}, {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local attributes
            if directories[path] then
                attributes = { mode = "directory", size = 0, modification = 0 }
            elseif files[path] then
                attributes = {
                    mode = "file",
                    size = #files[path],
                    modification = modified[path] or 0,
                }
            end
            return field and attributes and attributes[field] or attributes
        end,
        mkdir = function(path)
            directories[path] = true
            return true
        end,
        dir = function(path)
            local names = { ".", ".." }
            local prefix = path .. "/"
            for file_path in pairs(files) do
                if file_path:sub(1, #prefix) == prefix then
                    names[#names + 1] = file_path:sub(#prefix + 1)
                end
            end
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
    }
end

local CoverCache = require("weread.lib.cover_cache")
local function open_file(path, mode)
    expect(mode == "wb", "cover cache did not use binary writes")
    local data
    return {
        write = function(_self, value) data = value return true end,
        close = function() files[path] = data return true end,
    }
end
local function rename_file(from, to)
    files[to], files[from] = files[from], nil
    modified[to] = modified[from] or 0
    modified[from] = nil
    return true
end
local function remove_file(path)
    if files[path] then files[path] = nil return true end
    return nil
end

local locked = false
local render_hook
local cache = CoverCache:new({ data_dir = "/data/weread" }, {
    open_file = open_file,
    rename_file = rename_file,
    remove_file = remove_file,
    open_lease = function(path, options)
        expect(path == "/data/weread/shelf-covers.lock" and options.create and options.empty,
            "cover cache used the wrong lock")
        if locked then return nil, "busy" end
        locked = true
        return { release = function() locked = false end }
    end,
    render_thumbnail = function(source, target, width, height)
        expect(locked, "thumbnail was rendered without the write lock")
        expect(width == 300 and height == 450,
            "cover cache used the wrong thumbnail bounds")
        expect(files[source] ~= nil, "thumbnail source was not written first")
        files[target] = "\137PNG\r\n\26\n" .. string.rep("t", 20)
        if render_hook then render_hook(source, target) end
        return target
    end,
})
local book = { bookId = "one", cover = "https://cdn.example/one" }

expect(cache.dir == "/data/weread/shelf-covers", "cover cache used the wrong directory")
expect(cache:key(book) == cache:key(book) and #cache:key(book) == 32,
    "cover cache key was not a stable MD5 hash")
expect(cache:pathFor(book) == nil, "missing cover unexpectedly resolved to a file")

local jpeg = "\255\216\255" .. string.rep("j", 20)
local jpeg_path = assert(cache:store(book, jpeg))
expect(jpeg_path:match("%.thumb%.png$") and cache:pathFor(book) == jpeg_path,
    "JPEG cover was not converted to a bounded thumbnail")
expect(directories[cache.dir], "cover cache directory was not created")
files[jpeg_path] = ""
expect(cache:pathFor(book) == nil,
    "truncated cached cover was treated as renderable")
files[jpeg_path] = jpeg

local png_book = { cover = "https://cdn.example/two" }
local png = "\137PNG\r\n\26\n" .. string.rep("p", 20)
local png_path = assert(cache:store(png_book, png))
expect(png_path:match("%.thumb%.png$"), "PNG cover did not use the thumbnail suffix")
local legacy_book = { cover = "https://cdn.example/legacy" }
local legacy_path = cache.dir .. "/" .. cache:key(legacy_book) .. ".jpg"
files[legacy_path] = jpeg
expect(cache:sourcePathFor(legacy_book) == legacy_path,
    "legacy full-resolution cover was not found as a migration source")
local migrated_path = assert(cache:thumbnailFromCached(legacy_book))
expect(migrated_path:match("%.thumb%.png$") and files[legacy_path] == nil,
    "legacy cover was not replaced by a bounded thumbnail")
files[migrated_path] = nil
expect(cache:store({ cover = "https://cdn.example/bad" }, "not an image") == nil,
    "unsupported cover data was cached")
expect(cache:store({ cover = "https://cdn.example/tiny" }, "\255\216\255") == nil,
    "truncated image header was cached")

files[legacy_path] = jpeg
local staged_thumbnail
render_hook = function(source, target)
    staged_thumbnail = target
    local before = files[target]
    local stored, store_err = cache:store(png_book, png)
    local migrated, migration_err = cache:thumbnailFromCached(legacy_book)
    local pruned, prune_err = cache:prune(0)
    expect(not stored and store_err == "busy" and not migrated and migration_err == "busy"
        and not pruned and prune_err == "busy", "a cache writer bypassed the lease")
    expect(files[source] == jpeg and files[target] == before and files[legacy_path] == jpeg,
        "a competing operation altered the staged files")
    expect(cache:thumbnailFromCached(png_book) == png_path,
        "an already committed cover waited for a writer")
end
expect(cache:store(book, jpeg) == jpeg_path and not locked, "cover store did not release its lease")
render_hook = function() error("synthetic render failure") end
expect(cache:store(book, jpeg) == nil and not locked and cache:pathFor(book) == jpeg_path,
    "failed render leaked the lock or replaced the current cover")
render_hook = nil

local source_stage = cache.dir .. "/.source.part"
local old_source_stage = cache.dir .. "/" .. cache:key(png_book) .. ".source.part.webp"
local old_thumbnail_stage = cache.dir .. "/" .. cache:key(png_book) .. ".thumb.part.png"
files[source_stage], files[staged_thumbnail] = jpeg, png
files[old_source_stage], files[old_thumbnail_stage] = jpeg, png
expect(cache:prune(cache.MAX_BYTES) == 0 and not locked
    and not files[source_stage] and not files[staged_thumbnail]
    and not files[old_source_stage] and not files[old_thumbnail_stage],
    "pruning below the size limit did not reclaim interrupted writes")
expect(cache:pathFor(book) == jpeg_path and cache:pathFor(png_book) == png_path and files[legacy_path] == jpeg,
    "staging cleanup removed committed thumbnails or legacy inputs")
files[legacy_path] = nil

modified[jpeg_path], modified[png_path] = 1, 2
local removed = cache:prune(#files[png_path])
expect(removed == 1 and files[jpeg_path] == nil and files[png_path] ~= nil,
    "cover cache did not evict the oldest file at its size limit")

print(("cover_cache_spec: %d checks"):format(checks))
