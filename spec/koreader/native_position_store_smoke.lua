-- Synthetic data only; actual SQLite FULL commits and competing fork claims.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000';local settings={data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local library=require('weread.lib.library_db'):new(settings);local Store=require('weread.lib.native_position_store')
local store=Store:new(library,codec);local scope={vid=account,epoch=1}
local before={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17.5,summary='合成原摘要 \n😀'}
local desired=codec:json_decode(codec:json_encode(before));desired.chapter_offset=13;desired.summary='合成新摘要 \n😀'
local metadata={book_id='41',before=before,desired=desired,counts={readingTime=10,recordReadingTime=20,ttsTime=0},version=0,
    shelf_sha256=string.rep('a',64),source_sha256=string.rep('b',64),file_id='synthetic-file',basis='raw_txt_utf16'}
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
expect(store:read().phase=='idle');local prepared=assert(store:begin(metadata,scope,0))
expect(store:owns(prepared,'prepared'));expect(not store:begin(metadata,scope,0));expect(store:finish(prepared,'prepared'))
expect(not store:advance(prepared,'prepared','pending'),'cancelled intent dispatched')
prepared=assert(store:begin(metadata,scope,store:read().revision))
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counter=ffi.cast('int *',memory)
local function fork()
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then
        while counter[0]==0 do require('socket').sleep(.001) end
        if Store:new(library,codec):advance(prepared,'prepared','pending') then counter[1]=counter[1]+1 end
        ffi.C._exit(0)
    end
    return pid
end
local a,b=fork(),fork();counter[0]=1
for _i,pid in ipairs({a,b}) do local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid);expect(status[0]==0,'claim process failed') end
expect(counter[1]==1,'competing processes both claimed')
local reopened=Store:new(library,codec);local pending=assert(reopened:read())
expect(pending.phase=='pending' and pending.metadata.before.summary==before.summary)
expect(not reopened:advance(prepared,'prepared','pending'));expect(not reopened:finish(pending,'prepared'));expect(not reopened:finish(pending,'verified'))
expect(not reopened:advance(pending,'pending','verified'),'missing ACK promoted')
local open=library.open
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql)
        if sql=='COMMIT' then error('synthetic commit failure') end;return db:exec(sql)
    end,prepare=function(_self,sql) return db:prepare(sql) end,close=function() return db:close() end}
end
expect(not reopened:advance(pending,'pending','acknowledged'),'failed commit was accepted');library.open=open
expect(reopened:read().phase=='pending','rollback lost pending marker')
local ack=assert(reopened:advance(pending,'pending','acknowledged'))
expect(Store:new(library,codec):read().phase=='acknowledged','new process lost ACK')
local reader=tonumber(ffi.C.fork());assert(reader>=0)
if reader==0 then
    local value=Store:new(library,codec):read()
    ffi.C._exit(value and value.phase=='acknowledged' and value.metadata.desired.summary==desired.summary and 0 or 1)
end
local status=ffi.new('int[1]');assert(ffi.C.waitpid(reader,status,0)==reader);expect(status[0]==0,'fresh process lost ACK or full summary')
expect(not reopened:advance(pending,'pending','acknowledged'),'stale receipt reused')
account='900009';expect(store:read().phase=='idle' and not store:owns(ack));account='900000'
local verified=assert(Store:new(library,codec):advance(ack,'acknowledged','verified'))
expect(not store:finish(ack,'verified'),'old revision accepted')
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql) return db:exec(sql) end,prepare=function(_self,sql)
        expect(tonumber(db:rowexec('PRAGMA synchronous'))==2,'SQLite durability disabled');return db:prepare(sql)
    end,close=function() return db:close() end}
end
expect(store:finish(verified,'verified'));library.open=open
expect(not store:begin(metadata,{vid='900009',epoch=1},store:read().revision),'foreign owner created intent')
local db=assert(library:open());db:exec("UPDATE native_position_write_state SET payload='{}' WHERE id=1");db:close()
expect(not store:read() and not store:begin(metadata,scope,0),'corrupt original replaced')
ffi.C.munmap(memory,4096)
print('PASS native_position_store_smoke '..checks)
