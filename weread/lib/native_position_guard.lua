-- Anonymous cancellation bit shared with one direct worker child. It stores
-- no user data; a dead parent also invalidates the child's dispatch context.
local M={};M.__index=M
function M:new()
    local ffi=require('ffi');require('ffi/posix_h')
    if ffi.os~='Linux' and ffi.os~='OSX' then return nil end
    for _i,declaration in ipairs({'void *mmap(void *, size_t, int, int, int, long);','int munmap(void *, size_t);','int getpid(void);','int getppid(void);'}) do pcall(ffi.cdef,declaration) end
    local flag=ffi.os=='Linux' and 0x20 or 0x1000
    local ok,pointer=pcall(ffi.C.mmap,nil,4096,3,1+flag,-1,0)
    if not ok or pointer==ffi.cast('void *',-1) or pointer==nil then return nil end
    local cell=ffi.cast('volatile unsigned int *',pointer);cell[0]=1
    return setmetatable({ffi=ffi,cell=cell,owner=tonumber(ffi.C.getpid())},self)
end
function M:valid()
    if not self.cell then return false end
    local ffi=self.ffi;local pid=tonumber(ffi.C.getpid())
    if pid~=self.owner and tonumber(ffi.C.getppid())~=self.owner then return false end
    return self.cell[0]==1
end
function M:close()
    if not self.cell then return end
    local cell=self.cell;self.cell=nil;cell[0]=0;self.ffi.C.munmap(self.ffi.cast('void *',cell),4096)
end
-- Never hoist a shared cancellation check out of a network/settlement loop.
require('jit').off(M.valid,true)
return M
