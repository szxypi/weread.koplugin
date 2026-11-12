-- Worker-only, bounded reads from a new archive descriptor. Never extract to
-- disk, touch the reader's inherited native DOM/ZIP handles, or log content.
local M = { MAX_ENTRIES = 1000000, MAX_MEMBERS = 8, MAX_MEMBER_BYTES = 8 * 1024 * 1024 }
function M.read(path, wanted)
    if type(path) ~= 'string' or path == '' or #path > 4096 or path:find('%z') or type(wanted) ~= 'table' then
        return nil, 'source_archive/invalid'
    end
    local count = 0
    for name, maximum in pairs(wanted) do
        count = count + 1
        if type(name) ~= 'string' or #name > 1024 or type(maximum) ~= 'number' or maximum % 1 ~= 0
            or maximum < 1 or maximum > M.MAX_MEMBER_BYTES then return nil, 'source_archive/invalid' end
    end
    if count == 0 or count > M.MAX_MEMBERS then return nil, 'source_archive/invalid' end
    local archive, entry, lib, ffi
    local ok, result = pcall(function()
        ffi = require('ffi')
        require('ffi/libarchive_h')
        lib = ffi.loadlib('archive', '13')
        archive, entry = lib.archive_read_new(), lib.archive_entry_new()
        if archive == nil or entry == nil then return nil end
        if lib.archive_read_support_format_all(archive) ~= lib.ARCHIVE_OK
            or lib.archive_read_support_filter_all(archive) ~= lib.ARCHIVE_OK
            or lib.archive_read_open_filename(archive, path, 10240) ~= lib.ARCHIVE_OK then return nil end
        local members, found = {}, 0
        for _i = 1, M.MAX_ENTRIES do
            local status = lib.archive_read_next_header2(archive, entry)
            if status == lib.ARCHIVE_EOF then return found == count and members or nil end
            if status ~= lib.ARCHIVE_OK then return nil end
            local pointer = lib.archive_entry_pathname(entry)
            if pointer == nil then return nil end
            local name = ffi.string(pointer)
            local maximum = wanted[name]
            if maximum then
                if members[name] ~= nil or lib.archive_entry_filetype(entry) ~= lib.AE_IFREG then return nil end
                local size = tonumber(lib.archive_entry_size(entry))
                if not size or size < 0 or size > maximum or size % 1 ~= 0 then return nil end
                local chunks, total = {}, 0
                local buffer = ffi.new('char[?]', 65536)
                while true do
                    local read = tonumber(lib.archive_read_data(archive, buffer, 65536))
                    if not read or read < 0 then return nil end
                    if read == 0 then break end
                    total = total + read
                    if total > maximum or total > size then return nil end
                    chunks[#chunks + 1] = ffi.string(buffer, read)
                end
                if total ~= size then return nil end
                members[name], found = table.concat(chunks), found + 1
            end
        end
        return nil
    end)
    -- All paths close the independent descriptor, including malformed archives
    -- and duplicate requested members. Do not accept an early first match.
    if archive ~= nil and lib then pcall(lib.archive_read_close, archive); pcall(lib.archive_free, archive) end
    if entry ~= nil and lib then pcall(lib.archive_entry_free, entry) end
    if not ok or not result then return nil, 'source_archive/unavailable' end
    return result
end
return M
