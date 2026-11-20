require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local ffi=require('ffi');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local account='900000'
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local Queue=require('weread.lib.membership_queue_store');local store=Queue:new(library)
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
expect(#assert(store:list())==0,'new queue not empty')
local first=assert(store:put('41',false,true));expect(first.phase=='queued' and first.before==false and first.desired==true,'offline intent lost')
expect(not store:put('41',false,true),'existing intent replaced without comparison')
expect(not store:put('42',true,true),'no-op intent accepted')
local second=assert(store:put('41',true,false,first));expect(second.id~=first.id and not store:remove(first),'old token removed replacement')
expect(not store:transition(first,'dispatching'),'old token claimed replacement')
account='900099';expect(#assert(store:list())==0 and not store:remove(second),'account isolation failed');account='900000'
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counter=ffi.cast('int *',memory)
local function child()
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then
        while counter[0]==0 do require('socket').sleep(.001) end
        if store:transition(second,'dispatching') then counter[1]=counter[1]+1 end
        ffi.C._exit(0)
    end
    return pid
end
local a,b=child(),child();counter[0]=1
for _i,pid in ipairs({a,b}) do local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid);expect(status[0]==0,'claim child failed') end
local claimed=assert(Queue:new(library):get('41'))
expect(counter[1]==1 and claimed.phase=='dispatching','claim was not exclusive or durable')
expect(not store:transition(second,'dispatching') and not store:put('41',false,true,claimed),'possibly dispatched action was replayed')
local open=library.open
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return db:exec(sql) end,
        prepare=function(_self,sql) return db:prepare(sql) end,close=function() return db:close() end}
end
expect(not store:remove(claimed),'failed commit reported removal');library.open=open
expect(store:get('41').phase=='dispatching','rollback lost uncertain intent')
expect(store:remove(claimed) and not store:get('41'),'explicit removal failed')
local unsent=assert(store:put('43',false,true));local held=assert(store:transition(unsent,'dispatching'))
local released=assert(store:release_unsent(held))
expect(released.phase=='queued' and released.id==held.id and not store:release_unsent(held), 'proven-unsent release was not exact')
expect(store:remove(released),'released intent did not remain editable')
local queued=assert(store:put('42',true,false));local conflict=assert(store:transition(queued,'conflict'))
expect(conflict.phase=='conflict' and not store:transition(queued,'dispatching'),'conflict sent automatically')
local revised=assert(store:put('42',false,true,conflict));expect(revised.phase=='queued' and revised.id~=conflict.id,'explicit conflict replacement failed')
local db=assert(library:open());db:exec("UPDATE membership_offline_queue SET phase='unknown' WHERE book_id='42'");db:close()
expect(not store:list() and not store:get('42') and not store:remove(revised),'invalid row was silently replaced')
ffi.C.munmap(memory,4096)
print('PASS: offline membership queue SQLite, account and interruption ('..checks..' checks)')
