-- Exclusive local output on KOReader's Linux/Android/macOS POSIX targets.
local M={};M.__index=M
function M.create(directory,title,format)
    local ffi=require('ffi');require('ffi/posix_h')
    local bit=require('bit')
    if ffi.os~='Linux' and ffi.os~='OSX' then return nil end
    local lfs=require('libs/libkoreader-lfs')
    if type(directory)~='string' or #directory>3000 or directory:find('[%z%c]') then return nil end
    local ext=format=='markdown' and 'md' or format=='json' and 'json' or format=='epub' and 'epub'
    if not ext then return nil end
    local made=require('util').makePath(directory)
    if not made and lfs.attributes(directory,'mode')~='directory' then return nil end
    -- O_EXCL is absent from KOReader's generated posix_h. These are the
    -- Linux/Android and Darwin ABI values; use exclusive creation on FAT too.
    local exclusive=ffi.os=='OSX' and 0x800 or 0x80
    local flags=bit.bor(ffi.C.O_WRONLY,ffi.C.O_CREAT,ffi.C.O_CLOEXEC,exclusive)
    local prefix=directory..'/'..require('weread.lib.notes_export').filename(title)..'-'..os.date('%Y%m%d-%H%M%S')
    for index=1,10000 do
        local path=prefix..'-'..index..'.'..ext
        local fd=ffi.C.open(path,flags,ffi.cast('int',384))
        if fd>=0 then
            local identity=lfs.symlinkattributes(path)
            if not identity then ffi.C.close(fd);os.remove(path);return nil end
            return setmetatable({fd=tonumber(fd),path=path,identity=identity,ffi=ffi,lfs=lfs},M)
        end
        -- EEXIST is 17 on all supported targets; no existing file is opened.
        if ffi.errno()~=17 then return nil end
    end
end
function M:write(value)
    local at=0
    while at<#value do
        local n=tonumber(self.ffi.C.write(self.fd,self.ffi.cast('const char*',value)+at,#value-at))
        if n>0 then at=at+n
        elseif n>=0 or self.ffi.errno()~=self.ffi.C.EINTR then return false end
    end
    return true
end
function M:sync() return self.ffi.C.fsync(self.fd)==0 end
function M:close()
    local fd=self.fd;self.fd=nil
    if fd then return self.ffi.C.close(fd)==0 end
    return true
end
function M:owns()
    local value=self.path and self.lfs.symlinkattributes(self.path)
    return value and value.mode=='file' and value.ino==self.identity.ino and value.dev==self.identity.dev
end
function M:accept(bytes)
    local closed=self:close()
    local info=self.path and self.lfs.symlinkattributes(self.path)
    return closed and self:owns() and info.size==bytes
end
function M:abort()
    self:close()
    if self:owns() then os.remove(self.path) end
    self.path=nil
end
return M
