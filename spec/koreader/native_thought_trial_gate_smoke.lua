-- Actual SQLite rollback, concurrent claims, journal matching and restart.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default) return key=='account' and {user_vid='900000'} or default end}
local F=require('spec.helpers.thought_edit_fixture');local C=require('weread.lib.thought_edit_contract')
local Gate=dofile(arg[1]..'/spec/koreader/native_thought_trial_gate.lua');local Journal=require('weread.lib.thought_edit_store')
local journal=Journal:new(library,codec);local scope={vid='900000',epoch=1}
local snapshot=F.snapshot(codec);local plan=C.make(codec,snapshot,'create',F.mark(),'Synthetic test',F.marks(codec),{bookId='900001',version=77},'900000')
local input={book_id='900001',permit_writes=true,original_ids={'synthetic-note'},create_body=plan.body,edited_text='Synthetic edit'}
local gate=Gate:new(input,library,codec,root);local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
expect(not pcall(gate.claim,gate,'create',plan.body) and gate:read().phase=='create','missing production journal dispatched or failed rollback')
local record=assert(journal:begin(plan.metadata,scope,0));assert(journal:claim(record))
local wrong=F.clone(plan.body);wrong.isPrivate=0
expect(not pcall(gate.claim,gate,'create',wrong) and gate:read().posts==0,'public body passed gate')
wrong=F.clone(plan.body);wrong.content='Other text'
expect(not pcall(gate.claim,gate,'create',wrong) and gate:read().posts==0,'body mismatch passed gate')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counters=ffi.cast('int *',memory)
local function fork()
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then
        while counters[0]==0 do require('socket').sleep(.001) end
        if pcall(gate.claim,gate,'create',plan.body) then counters[1]=counters[1]+1 end
        ffi.C._exit(0)
    end
    return pid
end
local a,b=fork(),fork();counters[0]=1
for _i,pid in ipairs({a,b}) do local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid);expect(status[0]==0,'child failed') end
expect(counters[1]==1 and gate:read().posts==1,'concurrent creation claimed more than once')
local reopened=setmetatable({input=input,library=library,codec=codec,path=gate.path},Gate)
expect(not pcall(reopened.claim,reopened,'create',plan.body) and reopened:read().posts==1,'restart replayed possible dispatch')
expect(not pcall(reopened.advance,reopened,1,'synthetic-note') and reopened:read().phase=='create_pending','existing note became target')
assert(journal:finish(record,'pending'));reopened:advance(1,'synthetic-created')
local new=F.row();new.reviewId='synthetic-created';new.content='Synthetic test';snapshot.reviews[#snapshot.reviews+1]=new
plan=C.make(codec,snapshot,'edit',new,'Synthetic edit');record=assert(journal:begin(plan.metadata,scope,journal:read().revision));assert(journal:claim(record))
expect(reopened:claim('edit',plan.body) and reopened:read().posts==2,'verified new target edit refused')
expect(not pcall(reopened.claim,reopened,'edit',plan.body),'edit replayed')
assert(journal:finish(record,'pending'));reopened:advance(2,'synthetic-created')
new.content='Synthetic edit';plan=C.make(codec,snapshot,'delete',new);record=assert(journal:begin(plan.metadata,scope,journal:read().revision));assert(journal:claim(record))
expect(reopened:claim('delete',plan.body) and reopened:read().posts==3,'verified new target delete refused')
expect(not pcall(reopened.claim,reopened,'delete',plan.body),'delete replayed')
expect(not pcall(reopened.advance,reopened,2,'synthetic-created'),'completed trial advanced again')
assert(journal:finish(record,'pending'))
local dry=root..'/dry';assert(require('libs/libkoreader-lfs').mkdir(dry));input.permit_writes=false
plan=C.make(codec,F.snapshot(codec),'create',F.mark(),'Synthetic test',F.marks(codec),{bookId='900001',version=77},'900000')
record=assert(journal:begin(plan.metadata,scope,journal:read().revision));assert(journal:claim(record))
gate=Gate:new(input,library,codec,dry)
expect(gate:claim('create',plan.body)==false and gate:read().phase=='blocked' and gate:read().posts==0,'dry run dispatched')
expect(gate:read().preview.content=='Synthetic test' and journal:read().phase=='pending','dry preview/pending proof lost')
expect(not pcall(gate.claim,gate,'create',plan.body),'dry run could be resumed')
ffi.C.munmap(memory,4096)
print('PASS: native trial SQLite gate durability, race and rollback ('..checks..' checks)')
