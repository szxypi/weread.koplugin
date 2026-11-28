require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local ffi=require('ffi');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local account='900000';local Library=require('weread.lib.library_db')
local library=Library:new{data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local Store=require('weread.lib.reading_state_cache');local cache=Store:new(library,library:accountKey())
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
expect(cache:read('41')==nil,'new cache not empty')
expect(cache:write('41',false,nil),'initial observation failed')
local previous=assert(cache:read('41'));expect(previous.started==false,'initial value lost')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counter=ffi.cast('int *',memory)
local function fork(value)
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then
        while counter[0]==0 do require('socket').sleep(.001) end
        if cache:write('41',value,previous) then counter[1]=counter[1]+1 end;ffi.C._exit(0)
    end
    return pid
end
local a,b=fork(true),fork('missing');counter[0]=1
for _,pid in ipairs({a,b}) do local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid);expect(status[0]==0,'child failed') end
local latest=assert(cache:read('41'));expect(counter[1]==1 and latest.revision~=previous.revision,'concurrent cache writes not exclusive')
expect(not cache:write('41',false,previous),'stale read replaced newer value')
local reopened=Store:new(library,library:accountKey());expect(reopened:read('41').revision==latest.revision,'restart lost observation')
expect(reopened:write('CB_abc','missing',nil) and reopened:read('CB_abc').started=='missing','missing state was not preserved')
account='900099';expect(not cache:read('41') and not cache:write('41',false,latest),'cache followed account switch')
local other=Store:new(library,library:accountKey());expect(not other:read('41') and other:write('41',false,nil),'account data leaked')
account='900000';expect(cache:read('41').revision==latest.revision,'original account changed')
local open=library.open
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return db:exec(sql) end,
        prepare=function(_self,sql) return db:prepare(sql) end,close=function() return db:close() end}
end
expect(not cache:write('41',false,latest),'failed commit reported success');library.open=open
expect(cache:read('41').revision==latest.revision,'failed transaction changed cache')
local hash=require('weread.lib.crypto').sha256_hex('41');local db=assert(library:open())
local query=db:prepare('UPDATE profile_state SET payload=? WHERE name=?')
query:bind('{invalid','started_reading_cache_v1:'..hash):step();query:close();db:close()
expect(not cache:read('41') and not cache:write('41',true,nil),'corrupt cache was replaced')
ffi.C.munmap(memory,4096)
print('PASS: started-reading cache SQLite isolation, CAS and rollback ('..checks..' checks)')
