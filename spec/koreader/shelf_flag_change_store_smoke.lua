require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000';local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local Store=require('weread.lib.shelf_flag_change_store');local store=Store:new(library,codec)
local C=require('weread.lib.shelf_flag_change_contract');local metadata=C.make({books={{bookId='41',secret=0}}},
    {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=100,progress=37.5}},'41',true).metadata
local scope={vid='900000',epoch=1};local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
expect(store:read().phase=='idle','new journal not empty')
local record=assert(store:begin(metadata,scope,0));expect(store:owns(record,'prepared'),'prepared intent not durable')
expect(not store:begin(metadata,scope,0),'prepared intent replaced')
expect(store:finish(record,'prepared') and not store:claim(record),'cancelled preparation dispatched late')
record=assert(store:begin(metadata,scope,store:read().revision))
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counter=ffi.cast('int *',memory)
local function fork()
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then
        while counter[0]==0 do require('socket').sleep(.001) end
        if store:claim(record) then counter[1]=counter[1]+1 end;ffi.C._exit(0)
    end
    return pid
end
local a,b=fork(),fork();counter[0]=1
for _i,pid in ipairs({a,b}) do local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid);expect(status[0]==0,'claim child failed') end
expect(counter[1]==1 and store:read().phase=='pending','concurrent claim not exclusive')
local reopened=Store:new(library,codec);expect(reopened:owns(record,'pending') and not reopened:claim(record),'restart replayed possible dispatch')
expect(not reopened:finish(record,'prepared'),'pending cleared as unsent')
account='900099';expect(store:read().phase=='idle' and not store:owns(record),'account intent leaked');account='900000'
local open=library.open
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql) return db:exec(sql) end,prepare=function(_self,sql)
        expect(tonumber(db:rowexec('PRAGMA synchronous'))==2,'SQLite not FULL');return db:prepare(sql)
    end,close=function() return db:close() end}
end
expect(store:owns(record,'pending'),'FULL read failed');library.open=open
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return db:exec(sql) end,
        prepare=function(_self,sql) return db:prepare(sql) end,close=function() return db:close() end}
end
expect(not store:finish(record,'pending'),'failed commit reported success');library.open=open
expect(store:owns(record,'pending'),'rollback lost intent');expect(store:finish(record,'pending'),'verified state not finished')
local db=assert(library:open());db:exec("UPDATE shelf_flag_write_state SET payload='{}' WHERE id=1");db:close()
expect(not store:read() and not store:begin(metadata,scope,store:read() and 0),'corrupt intent replaced')
ffi.C.munmap(memory,4096)
print('PASS: private-reading SQLite FULL, rollback and fork claim ('..checks..' checks)')
