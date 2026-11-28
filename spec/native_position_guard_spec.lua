package.path='./?.lua;'..package.path
local ffi=require('ffi')
-- Standalone CI has LuaJIT/libc but no KOReader header search path.
package.loaded['ffi/posix_h']={}
ffi.cdef[[int fork(void); int waitpid(int,int *,int); void _exit(int); int usleep(unsigned int);]]
local Guard=require('weread.lib.native_position_guard')
local checks=0;local function expect(value) checks=checks+1;assert(value) end
local guard=assert(Guard:new());expect(guard:valid())
local pointer=guard.cell;local owner=guard.owner
guard.owner=owner+100000;expect(not guard:valid());guard.owner=owner
local child=tonumber(ffi.C.fork());assert(child>=0)
if child==0 then
    local ok=guard:valid();pointer[1]=1
    while pointer[0]==1 and guard:valid() do ffi.C.usleep(1000) end
    ffi.C._exit(ok and not guard:valid() and 0 or 1)
end
local deadline=os.time()+5
while pointer[1]==0 do assert(os.time()<=deadline);ffi.C.usleep(1000) end
guard:close();local status=ffi.new('int[1]');assert(ffi.C.waitpid(child,status,0)==child)
expect(status[0]==0);expect(not guard:valid());guard:close();expect(not guard:valid())
print('PASS native_position_guard_spec '..checks)
