-- Synthetic SQLite archive: atomic unknown tombstone + idle, never a POST.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000';local settings={data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid=account} or default end}
local library=require('weread.lib.library_db'):new(settings);local Store=require('weread.lib.native_position_store')
local f=require('spec.helpers.native_position_review_fixture').new();local metadata=f.row.metadata
local store=Store:new(library,codec);local scope={vid=account,epoch=1};local observation=f.observation
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why) end
local function pending()
    local row=assert(store:begin(metadata,scope,store:read().revision));return assert(store:advance(row,'prepared','pending'))
end
local record=pending();local open=library.open
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql) if sql=='COMMIT' then error('synthetic commit failure') end;return db:exec(sql) end,
        prepare=function(_self,sql) return db:prepare(sql) end,close=function() return db:close() end}
end
expect(not store:archive(record,observation),'failed commit accepted');library.open=open
expect(store:read().phase=='pending','rollback lost unknown intent')
local db=assert(open(library));expect(tonumber(db:rowexec('SELECT COUNT(*) FROM native_position_write_history'))==0,'rollback kept tombstone');db:close()
local changed=codec:json_decode(codec:json_encode(record));changed.revision=changed.revision+1
expect(not store:archive(changed,observation),'stale revision archived')
local other=codec:json_decode(codec:json_encode(observation));other.point.book_id='42';expect(not store:archive(record,other),'wrong book archived')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counter=ffi.cast('int *',memory)
local children={}
for _i=1,2 do
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then
        while counter[0]==0 do require('socket').sleep(.001) end
        if Store:new(library,codec):archive(record,observation) then counter[1]=counter[1]+1 end
        ffi.C._exit(0)
    end
    children[#children+1]=pid
end
counter[0]=1
for _i,pid in ipairs(children) do local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid);expect(status[0]==0) end
expect(counter[1]==1,'competing archives both committed');expect(store:read().phase=='idle')
expect(not store:advance(record,'pending','acknowledged'),'archived unknown accepted late ACK')
expect(not store:archive(record,observation),'old local choice replayed')
db=assert(open(library));local raw=db:rowexec('SELECT payload FROM native_position_write_history');db:close()
local archived=json.decode(raw);expect(archived.phase=='pending' and archived.current_matches_target==true,'unknown relabelled as success')
expect(not raw:find(metadata.before.summary,1,true) and archived.metadata_sha256 and archived.cloud_sha256,'summary persisted in tombstone')
local prepared=assert(store:begin(metadata,scope,store:read().revision));expect(prepared.id~=record.id and prepared.revision>record.revision)
expect(store:archive(prepared,observation),'unclaimed record could not be retired')
for _i=1,34 do record=pending();expect(store:archive(record,observation)) end
db=assert(open(library));expect(tonumber(db:rowexec('SELECT COUNT(*) FROM native_position_write_history'))==32,'history unbounded');db:close()
local child=tonumber(ffi.C.fork());assert(child>=0)
if child==0 then
    local row=Store:new(library,codec):read();local connection=assert(library:open());local count=tonumber(connection:rowexec('SELECT COUNT(*) FROM native_position_write_history'));connection:close()
    ffi.C._exit(row.phase=='idle' and count==32 and 0 or 1)
end
local status=ffi.new('int[1]');assert(ffi.C.waitpid(child,status,0)==child);expect(status[0]==0,'fresh process lost archive')
account='900009';expect(store:read().phase=='idle' and not store:archive(record,observation),'cross-account archive')
ffi.C.munmap(memory,4096)
print('PASS native_position_review_store_smoke '..checks)
