-- Stream into the exclusively created descriptor, never reopen an output name.
-- libarchive's fd writer leaves descriptor ownership with the caller.
local M={};M.__index=M
local function fail() error('mp_export/archive_failed',0) end
function M.new(fd)
    local ffi=require('ffi');require('ffi/libarchive_h')
    ffi.cdef[[int archive_write_open_fd(struct archive *, int);
        int archive_write_set_bytes_in_last_block(struct archive *, int);]]
    local lib=ffi.loadlib('archive','13')
    local archive=lib.archive_write_new()
    if archive==nil then fail() end
    local self=setmetatable({ffi=ffi,lib=lib,archive=archive},M)
    if lib.archive_write_set_format_by_name(archive,'zip')~=lib.ARCHIVE_OK
        or lib.archive_write_set_bytes_in_last_block(archive,1)~=lib.ARCHIVE_OK
        or lib.archive_write_open_fd(archive,fd)~=lib.ARCHIVE_OK then self:close();fail() end
    return self
end
function M:add(name,source,size,store)
    local ffi,lib,archive=self.ffi,self.lib,self.archive
    local entry=lib.archive_entry_new()
    if entry==nil then fail() end
    local ok=pcall(function()
        local compression=store and lib.archive_write_zip_set_compression_store or lib.archive_write_zip_set_compression_deflate
        if compression(archive)~=lib.ARCHIVE_OK then fail() end
        lib.archive_entry_set_pathname(entry,name)
        lib.archive_entry_set_filetype(entry,lib.AE_IFREG)
        lib.archive_entry_set_perm(entry,420)
        lib.archive_entry_set_size(entry,size)
        if lib.archive_write_header(archive,entry)~=lib.ARCHIVE_OK then fail() end
        local written=0
        while written<size do
            local chunk=type(source)=='string' and source:sub(written+1,math.min(size,written+65536)) or source()
            if type(chunk)~='string' or #chunk==0 or written+#chunk>size then fail() end
            local offset=0
            while offset<#chunk do
                local count=tonumber(lib.archive_write_data(archive,ffi.cast('const char*',chunk)+offset,#chunk-offset))
                if not count or count<=0 then fail() end
                offset=offset+count
            end
            written=written+#chunk
        end
    end)
    lib.archive_entry_free(entry)
    if not ok then fail() end
end
function M:close()
    local archive=self.archive;self.archive=nil
    if not archive then return true end
    local ok=self.lib.archive_write_close(archive)==self.lib.ARCHIVE_OK
    local freed=self.lib.archive_free(archive)==self.lib.ARCHIVE_OK
    return ok and freed
end
return M
