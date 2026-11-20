-- Nonblocking descriptor leases, including bounded immutable ownership records.
local M={}
local function fs() return require('libs/libkoreader-lfs') end
local function same(a,b) return a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino end
function M.open(path,options)
    options=options or {}
    if type(path)~='string' or #path>4096 or path:find('[%z%c]') then return nil,'unavailable' end
    local parent=path:match('^(.*)/[^/]+$');local owner=parent and fs().symlinkattributes(parent)
    if not owner or owner.mode~='directory' then return nil,options.create and 'unavailable' or 'absent' end
    local previous=fs().symlinkattributes(path)
    if not previous and not options.create then return nil,'absent' end
    if previous and (previous.mode~='file' or options.empty and previous.size~=0) then return nil,'unavailable' end
    if previous and options.exclusive then return nil,'exists' end
    local ffi=require('ffi');require('ffi/posix_h')
    if ffi.os~='Linux' and ffi.os~='OSX' then return nil,'unsupported' end
    pcall(ffi.cdef,'int flock(int fd, int operation);')
    pcall(ffi.cdef,'long pread(int fd, void *buffer, unsigned long count, long offset);')
    if not pcall(function() return ffi.C.flock end) then return nil,'unsupported' end
    local flags=require('bit').bor(ffi.C.O_RDWR,ffi.C.O_CLOEXEC,options.create and ffi.C.O_CREAT or 0,
        options.exclusive and (ffi.os=='OSX' and 0x800 or 0x80) or 0,ffi.os=='OSX' and 0x100 or 0x20000)
    local fd=tonumber(ffi.C.open(path,flags,ffi.cast('int',384)))
    if fd<0 then return nil,'unavailable' end
    local info=fs().symlinkattributes(path)
    local descriptor=fs().attributes((ffi.os=='OSX' and '/dev/fd/' or '/proc/self/fd/')..fd)
    if not same(info,descriptor) or info.mode~='file' or options.empty and info.size~=0 or not same(owner,fs().symlinkattributes(parent)) then
        ffi.C.close(fd);return nil,'unavailable'
    end
    if ffi.C.flock(fd,6)~=0 then
        local errno=ffi.errno();ffi.C.close(fd)
        local unsupported=ffi.os=='OSX' and ({[78]=true,[102]=true,[45]=true}) or ({[38]=true,[95]=true})
        return nil,unsupported[errno] and 'unsupported' or 'busy'
    end
    local lease={path=path,info=info,fd=fd}
    function lease:owns() return self.fd and same(self.info,fs().symlinkattributes(self.path)) end
    function lease:read(limit)
        if not self:owns() or type(limit)~='number' or limit<1 or limit>16384 or self.info.size>limit then return nil end
        local buffer=ffi.new('char[?]',limit+1);local n=tonumber(ffi.C.pread(self.fd,buffer,limit+1,0))
        local now=fs().symlinkattributes(self.path)
        if n<0 or n>limit or not same(self.info,now) or now.size~=n or now.modification~=self.info.modification then return nil end
        return ffi.string(buffer,n)
    end
    function lease:write(raw)
        if not options.exclusive or not self:owns() or self.info.size~=0 or type(raw)~='string' or #raw>16384 then return false end
        local offset=0
        while offset<#raw do
            local n=tonumber(ffi.C.write(self.fd,ffi.cast('const char*',raw)+offset,#raw-offset))
            if n>0 then offset=offset+n elseif n>=0 or ffi.errno()~=ffi.C.EINTR then break end
        end
        local durable=ffi.C.fsync(self.fd)==0
        local now=fs().symlinkattributes(self.path)
        if not same(self.info,now) then return false end;self.info=now
        return offset==#raw and durable and self:read(16384)==raw
    end
    function lease:remove()
        local now=fs().symlinkattributes(self.path)
        return self:owns() and now.size==self.info.size and now.modification==self.info.modification and os.remove(self.path) or false
    end
    function lease:release()
        if self.fd then ffi.C.flock(self.fd,8);ffi.C.close(self.fd);self.fd=nil end
    end
    return lease
end
M.same=same
return M
