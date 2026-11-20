-- Open the selected regular file without following a replacement symlink.
local M={}
local function same(a,b)
    return a and b and a.mode=='file' and b.mode=='file' and a.dev~=nil and a.ino~=nil
        and a.dev==b.dev and a.ino==b.ino and a.size==b.size
        and a.modification==b.modification and a.change==b.change
end
function M.open(input)
    if type(input)~='table' or type(input.path)~='string' or type(input.identity)~='table' then return nil end
    local ffi=require('ffi');require('ffi/posix_h')
    if ffi.os~='Linux' and ffi.os~='OSX' then return nil end
    local lfs=require('libs/libkoreader-lfs')
    if not same(input.identity,lfs.symlinkattributes(input.path)) then return nil end
    local flags=require('bit').bor(ffi.C.O_RDONLY,ffi.C.O_CLOEXEC,ffi.C.O_NONBLOCK,ffi.os=='OSX' and 0x100 or 0x20000)
    local fd=tonumber(ffi.C.open(input.path,flags))
    if fd<0 then return nil end
    local descriptor=lfs.attributes((ffi.os=='OSX' and '/dev/fd/' or '/proc/self/fd/')..fd)
    if not same(input.identity,descriptor) or not same(input.identity,lfs.symlinkattributes(input.path)) then ffi.C.close(fd);return nil end
    local buffer=ffi.new('char[?]',65536);local obj={fd=fd}
    function obj:read(limit)
        if not self.fd or type(limit)~='number' or limit<1 or limit>65536 then error('personal_upload/read',0) end
        local count
        repeat count=tonumber(ffi.C.read(self.fd,buffer,limit)) until count>=0 or ffi.errno()~=ffi.C.EINTR
        if count<0 then error('personal_upload/read',0) end
        if count==0 then return nil end
        return ffi.string(buffer,count)
    end
    function obj:seek() return self.fd and ffi.C.lseek(self.fd,0,0)==0 and 0 or nil end
    function obj:close() if self.fd then ffi.C.close(self.fd);self.fd=nil end end
    return obj
end
return M
