-- Bounded reads from a new archive descriptor. Never extract to
-- disk, touch the reader's inherited native DOM/ZIP handles, or log content.
local Catalog = require('weread.lib.chapter_catalog')
local M = { MAX_ENTRIES = 1000000, MAX_MEMBERS = 8, MAX_MEMBER_BYTES = 8 * 1024 * 1024 }
M.MAX_BATCH_MEMBERS = 4097
M.MAX_BATCH_BYTES = 16 * 1024 * 1024
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
local function read_members(path, wanted, batch, zip_probe, discard_data)
    if type(path) ~= 'string' or path == '' or #path > 4096 or path:find('%z') or type(wanted) ~= 'table' then
        return nil, 'source_archive/invalid'
    end
    local count = 0
    for name, maximum in pairs(wanted) do
        count = count + 1
        local limit = name == 'OEBPS/content.opf' and Catalog.MAX_PACKAGE_BYTES or M.MAX_MEMBER_BYTES
        if type(name) ~= 'string' or #name > 1024 or type(maximum) ~= 'number' or maximum % 1 ~= 0
            or maximum < 1 or maximum > limit then return nil, 'source_archive/invalid' end
    end
    if count == 0 or count > (batch and M.MAX_BATCH_MEMBERS or M.MAX_MEMBERS) then return nil, 'source_archive/invalid' end
    local archive, entry, lib, ffi, zip_supported, limit_exceeded
    local ok, result = pcall(function()
        ffi = require('ffi')
        require('ffi/libarchive_h')
        lib = ffi.loadlib('archive', '13')
        archive, entry = lib.archive_read_new(), lib.archive_entry_new()
        if archive == nil or entry == nil then return nil end
        if zip_probe then
            ffi.cdef[[int archive_read_support_format_zip_seekable(struct archive *);]]
            if lib.archive_read_support_format_zip_seekable(archive) ~= lib.ARCHIVE_OK then return nil end
            zip_supported = true
        elseif lib.archive_read_support_format_all(archive) ~= lib.ARCHIVE_OK
            or lib.archive_read_support_filter_all(archive) ~= lib.ARCHIVE_OK then return nil end
        if lib.archive_read_open_filename(archive, path, 10240) ~= lib.ARCHIVE_OK then return nil end
        local members, found, used = {}, 0, 0
        local unreadable
        local buffer = ffi.new('char[?]', 65536)
        for _i = 1, M.MAX_ENTRIES do
            local status = lib.archive_read_next_header2(archive, entry)
            if status == lib.ARCHIVE_EOF then return (batch or found == count) and members or nil end
            if status ~= lib.ARCHIVE_OK then return nil end
            local pointer = lib.archive_entry_pathname(entry)
            if pointer == nil then return nil end
            local name = ffi.string(pointer)
            local maximum = wanted[name]
            if maximum then
                if members[name] ~= nil or unreadable and unreadable[name]
                    or lib.archive_entry_filetype(entry) ~= lib.AE_IFREG then return nil end
                local size = tonumber(lib.archive_entry_size(entry))
                limit_exceeded = size and size > maximum
                if not size or size < 0 or size > maximum or size % 1 ~= 0 then return nil end
                used = used + size
                if batch and used > M.MAX_BATCH_BYTES then return nil end
                local chunks, total = not discard_data and {} or nil, 0
                while true do
                    local read = tonumber(lib.archive_read_data(archive, buffer, 65536))
                    if not read then return nil end
                    if read < 0 then
                        if not batch or read < lib.ARCHIVE_FAILED then return nil end
                        -- A recoverable member error invalidates all bytes of that
                        -- member. Continue only if subsequent headers reach EOF.
                        unreadable = unreadable or {}
                        unreadable[name] = true
                        break
                    end
                    if read == 0 then break end
                    total = total + read
                    if total > maximum or total > size then return nil end
                    if chunks then chunks[#chunks + 1] = ffi.string(buffer, read) end
                end
                if not unreadable or not unreadable[name] then
                    if total ~= size then return nil end
                    members[name], found = chunks and table.concat(chunks) or total, found + 1
                    if zip_probe and found == count then return members end
                end
            end
        end
        return nil
    end)
    -- Full reads validate through EOF. Quick ZIP probes stop after the requested
    -- members have been read and checked by the archive reader.
    if archive ~= nil and lib then pcall(lib.archive_read_close, archive); pcall(lib.archive_free, archive) end
    if entry ~= nil and lib then pcall(lib.archive_entry_free, entry) end
    if zip_probe and not zip_supported then return nil, 'source_archive/zip_probe_unsupported' end
    if discard_data and limit_exceeded then return nil, 'source_archive/zip_probe_limit' end
    if not ok or not result then return nil, 'source_archive/unavailable' end
    return result
end

function M.read(path, wanted)
    return read_members(path, wanted, false)
end

-- The seekable ZIP reader requires the central directory. Read just the
-- required EPUB container entry before handing the candidate to ReaderUI.
function M.epub_container_readable(path)
    local name = 'META-INF/container.xml'
    local members, reason = read_members(path, { [name] = 1024 * 1024 }, false, true)
    if reason == 'source_archive/zip_probe_unsupported' then return nil end
    return members ~= nil and members[name] ~= ''
end

function M.epub_chapter_readable(path, member)
    -- Reading through the member validates its ZIP checksum, using one buffer.
    local members, reason = read_members(path, { [member] = M.MAX_MEMBER_BYTES }, false, true, true)
    if reason == 'source_archive/zip_probe_unsupported' or reason == 'source_archive/zip_probe_limit' then return nil end
    return members ~= nil and members[member] > 0
end

-- Missing members and recoverable data errors are checked per snapshot.
-- Ambiguous names, invalid headers and budget violations still stop the batch.
function M.read_batch(path, wanted)
    return read_members(path, wanted, true)
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
function M.position_metadata(path,visit)
    if type(path)~='string' or path=='' or #path>4096 or path:find('[%z%c]')
        or visit~=nil and type(visit)~='function' then return nil end
    local archive,entry,lib,ffi
    local max_count=visit and Catalog.MAX_CHAPTERS or 10000
    local max_bytes=(visit and 16 or 8)*1024*1024
    local ok,result=pcall(function()
        ffi=require('ffi');require('ffi/libarchive_h');lib=ffi.loadlib('archive','13')
        archive,entry=lib.archive_read_new(),lib.archive_entry_new()
        if archive==nil or entry==nil or lib.archive_read_support_format_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_support_filter_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_open_filename(archive,path,10240)~=lib.ARCHIVE_OK then return nil end
        local found,seen,total,count=visit and true or {},{},0,0
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
                    or size<1 or size>4096 or count>=max_count or total+size>max_bytes then return nil end
                seen[name]=true;total=total+size;count=count+1
                local chunks,used={},0
                while true do
                    local bytes=tonumber(lib.archive_read_data(archive,buffer,4096))
                    if not bytes or bytes<0 then return nil end
                    if bytes==0 then break end
                    used=used+bytes;if used>size then return nil end
                    chunks[#chunks+1]=ffi.string(buffer,bytes)
                end
                if used~=size then return nil end
                local metadata=table.concat(chunks)
                if visit then
                    if visit(name,metadata)==false then return nil end
                else found[count]={name=name,metadata=metadata} end
            end
        end
    end)
    if archive~=nil and lib then pcall(lib.archive_read_close,archive);pcall(lib.archive_free,archive) end
    if entry~=nil and lib then pcall(lib.archive_entry_free,entry) end
    return ok and result or nil
end
return M
