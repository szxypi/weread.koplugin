-- Worker-only, bounded reads from a new archive descriptor. Never extract to
-- disk, touch the reader's inherited native DOM/ZIP handles, or log content.
local M = { MAX_ENTRIES = 1000000, MAX_MEMBERS = 8, MAX_MEMBER_BYTES = 8 * 1024 * 1024 }
local compare_bytes
local function byte_comparator(ffi)
    if compare_bytes == nil then
        local ok, compare = pcall(function()
            ffi.cdef[[int memcmp(const void *, const void *, size_t);]]
            local fn=ffi.C.memcmp
            assert(fn('a','a',1)==0 and fn('a','b',1)~=0)
            return fn
        end)
        compare_bytes=ok and compare or false
    end
    return compare_bytes
end
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
-- Verify many known members in a single pass, retaining at most one member's
-- bytes. This is for worker-side whole-book checks, not archive extraction.
-- Every requested member must occur exactly once, even after an early match.
-- Each member uses expected bytes, an expected digest, or a bounded validator.
function M.verify_members(path, wanted)
    if type(path)~='string' or path=='' or #path>4096 or path:find('[%z%c]') or type(wanted)~='table' then return false end
    local count=0
    for name,item in pairs(wanted) do
        count=count+1
        if type(name)~='string' or #name>1024 or type(item)~='table'
            or type(item.maximum)~='number' or item.maximum%1~=0 or item.maximum<1 or item.maximum>M.MAX_MEMBER_BYTES
            or item.size~=nil and (type(item.size)~='number' or item.size%1~=0 or item.size<0 or item.size>item.maximum)
            or item.bytes~=nil and (type(item.bytes)~='string' or #item.bytes>item.maximum)
            or item.sha256~=nil and (type(item.sha256)~='string' or #item.sha256~=64 or not item.sha256:match('^[a-f0-9]+$'))
            or item.validate~=nil and type(item.validate)~='function' then return false end
        local methods=(item.bytes~=nil and 1 or 0)+(item.sha256~=nil and 1 or 0)+(item.validate~=nil and 1 or 0)
        if methods~=1 then return false end
    end
    if count<1 or count>40001 then return false end
    local archive,entry,lib,ffi
    local ok,result=pcall(function()
        ffi=require('ffi');require('ffi/libarchive_h');lib=ffi.loadlib('archive','13')
        archive,entry=lib.archive_read_new(),lib.archive_entry_new()
        if archive==nil or entry==nil or lib.archive_read_support_format_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_support_filter_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_open_filename(archive,path,10240)~=lib.ARCHIVE_OK then return false end
        local seen,found={},0
        local buffer=ffi.new('char[?]',65536)
        local compare=byte_comparator(ffi)
        for _i=1,M.MAX_ENTRIES do
            local status=lib.archive_read_next_header2(archive,entry)
            if status==lib.ARCHIVE_EOF then return found==count end
            if status~=lib.ARCHIVE_OK then return false end
            local pointer=lib.archive_entry_pathname(entry);if pointer==nil then return false end
            local name=ffi.string(pointer);local item=wanted[name]
            if item then
                if seen[name] or lib.archive_entry_filetype(entry)~=lib.AE_IFREG then return false end
                local size=tonumber(lib.archive_entry_size(entry))
                if not size or size<0 or size%1~=0 or size>item.maximum or item.size~=nil and size~=item.size
                    or item.bytes~=nil and #item.bytes~=size then return false end
                local chunks,total=item.bytes==nil and {} or nil,0
                local expected=compare and item.bytes~=nil and ffi.cast('const unsigned char *',item.bytes) or nil
                while true do
                    local n=tonumber(lib.archive_read_data(archive,buffer,65536))
                    if not n or n<0 then return false end
                    if n==0 then break end
                    total=total+n;if total>size or total>item.maximum then return false end
                    if item.bytes~=nil then
                        if expected then
                            if compare(buffer,expected+total-n,n)~=0 then return false end
                        elseif ffi.string(buffer,n)~=item.bytes:sub(total-n+1,total) then return false end
                    else chunks[#chunks+1]=ffi.string(buffer,n) end
                end
                if total~=size then return false end
                if item.sha256~=nil and require('weread.lib.crypto').sha256_hex(table.concat(chunks))~=item.sha256 then return false end
                if item.validate~=nil and item.validate(table.concat(chunks))~=true then return false end
                seen[name]=true;found=found+1
            end
        end
        return false
    end)
    if archive~=nil and lib then pcall(lib.archive_read_close,archive);pcall(lib.archive_free,archive) end
    if entry~=nil and lib then pcall(lib.archive_entry_free,entry) end
    return ok and result==true
end
-- Discover only sealed per-chapter metadata; raw and rendered chapter bytes
-- remain subject to the independent bounded read and hash verification above.
function M.position_metadata(path)
    if type(path)~='string' or path=='' or #path>4096 or path:find('[%z%c]') then return nil end
    local archive,entry,lib,ffi
    local ok,result=pcall(function()
        ffi=require('ffi');require('ffi/libarchive_h');lib=ffi.loadlib('archive','13')
        archive,entry=lib.archive_read_new(),lib.archive_entry_new()
        if archive==nil or entry==nil or lib.archive_read_support_format_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_support_filter_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_open_filename(archive,path,10240)~=lib.ARCHIVE_OK then return nil end
        local found,seen,total={},{},0
        local buffer=ffi.new('char[?]',4096)
        for _i=1,M.MAX_ENTRIES do
            local status=lib.archive_read_next_header2(archive,entry)
            if status==lib.ARCHIVE_EOF then return found end
            if status~=lib.ARCHIVE_OK then return nil end
            local pointer=lib.archive_entry_pathname(entry);if pointer==nil then return nil end
            local name=ffi.string(pointer)
            local digest=name:match('^OEBPS/weread%-position/uid%-([0-9a-f]+)%.meta$')
            if digest and #digest==64 then
                local size=tonumber(lib.archive_entry_size(entry))
                if seen[name] or lib.archive_entry_filetype(entry)~=lib.AE_IFREG or not size or size%1~=0
                    or size<1 or size>4096 or #found>=10000 or total+size>8*1024*1024 then return nil end
                seen[name]=true;total=total+size
                local chunks,used={},0
                while true do
                    local count=tonumber(lib.archive_read_data(archive,buffer,4096))
                    if not count or count<0 then return nil end
                    if count==0 then break end
                    used=used+count;if used>size then return nil end
                    chunks[#chunks+1]=ffi.string(buffer,count)
                end
                if used~=size then return nil end
                found[#found+1]={name=name,metadata=table.concat(chunks)}
            end
        end
    end)
    if archive~=nil and lib then pcall(lib.archive_read_close,archive);pcall(lib.archive_free,archive) end
    if entry~=nil and lib then pcall(lib.archive_entry_free,entry) end
    return ok and result or nil
end
return M
