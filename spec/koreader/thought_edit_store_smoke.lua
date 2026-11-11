-- Real SQLite, fork races, interrupted dispatch state and bounded drafts.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(require('libs/libkoreader-lfs').mkdir(root))
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000';local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default)
    return key=='account' and {user_vid=account} or default end}
local F=require('spec.helpers.thought_edit_fixture');local C=require('weread.lib.thought_edit_contract')
local Store=require('weread.lib.thought_edit_store');local store=Store:new(library,codec)
local metadata=C.make(codec,F.snapshot(codec),'edit',F.row(),'New text').metadata
local scope={vid='900000',epoch=1};local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
expect(store:read().phase=='idle','new journal not idle')
local draft=assert(store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'New text'))
expect(store:draft(draft.draft_key).content=='New text','draft not durable')
local record,reason=store:begin(metadata,scope,0,draft);expect(record and not reason and record.phase=='prepared','prepare not durable')
expect(not store:begin(metadata,scope,0,draft),'stale revision prepared twice')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counter=ffi.cast('int *',memory)
local function fork(task)
    local pid=tonumber(ffi.C.fork());assert(pid>=0)
    if pid==0 then local ok=pcall(task);ffi.C._exit(ok and 0 or 1) end
    return pid
end
local function reap(pid)
    local status=ffi.new('int[1]');assert(ffi.C.waitpid(pid,status,0)==pid);expect(status[0]==0,'child failed')
end
local function race()
    while counter[1]==0 do require('socket').sleep(.001) end
    if store:claim(record) then counter[0]=counter[0]+1 end
end
local a=fork(race);local b=fork(race);counter[1]=1
reap(a);reap(b)
expect(counter[0]==1 and store:read().phase=='pending','concurrent dispatch claim was not exclusive')
expect(not store:claim(record) and not store:finish(record,'prepared'),'pending state replayed or cancelled as unsent')
local fresh=Store:new(library,codec);expect(fresh:owns(record,'pending'),'restart forgot possible dispatch')
expect(fresh:finish(record,'pending') and not fresh:draft(draft.draft_key),'confirmed completion did not remove matching draft')
expect(not fresh:finish(record,'pending'),'old completion accepted')
draft=assert(store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Draft old'))
local previous=draft;draft=assert(store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Draft replacement'))
expect(not store:delete_draft(previous) and store:draft(draft.draft_key).content=='Draft replacement','old draft callback deleted replacement')
record=assert(store:begin(metadata,scope,store:read().revision,draft))
expect(store:finish(record,'prepared') and store:draft(draft.draft_key),'unsent cancellation deleted draft')
expect(not store:claim(record),'cancelled child claimed later')
record=assert(store:begin(metadata,scope,store:read().revision,draft));assert(store:claim(record))
local replacement=assert(store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Newer draft'))
expect(store:finish(record,'pending') and store:draft(draft.draft_key).token==replacement.token,'pending completion deleted newer draft')
record=assert(store:begin(metadata,scope,store:read().revision,replacement));assert(store:claim(record))
expect(store:finish(record,'pending',true) and store:draft(draft.draft_key),'accept-current discarded uncertain draft')
for i=2,16 do expect(store:save_draft('900001','edit','synthetic-'..i,C.row_hash(F.row()),'Draft '..i),'draft quota failed early') end
expect(#store:drafts()==16 and not store:save_draft('900001','edit','overflow',C.row_hash(F.row()),'Overflow'),'draft quota evicted data or overflowed')
expect(store:save_draft('900001','edit','synthetic-2',C.row_hash(F.row()),'Replacement at quota'),'quota blocked replacement')
account='900099';expect(store:read().phase=='idle' and #store:drafts()==0,'account data leaked');account='900000'
local open=library.open
local full_checks=0
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql) return db:exec(sql) end,
        prepare=function(_self,sql)
            expect(tonumber(db:rowexec('PRAGMA synchronous'))==2,'intent connection not synchronous FULL')
            full_checks=full_checks+1;return db:prepare(sql)
        end,rowexec=function(_self,sql) return db:rowexec(sql) end,close=function() return db:close() end}
end
expect(store:read().phase=='idle' and full_checks>0,'FULL connection not exercised');library.open=open
function library:open()
    local db=assert(open(self));return {exec=function(_self,sql)
        if sql=='COMMIT' then error('synthetic commit fault') end;return db:exec(sql)
    end,prepare=function(_self,sql) return db:prepare(sql) end,rowexec=function(_self,sql) return db:rowexec(sql) end,
        close=function() return db:close() end}
end
expect(not store:delete_draft(replacement),'failed commit reported success');library.open=open
expect(store:draft(replacement.draft_key)~=nil,'failed commit lost draft')
local db=assert(library:open());local row=db:rowexec('SELECT payload FROM thought_write_state')
expect(not row:find('New text',1,true) and not row:find('合成引用',1,true),'journal stored text')
db:exec("UPDATE thought_write_state SET payload='{}' WHERE id=1");db:close()
expect(not store:read() and not store:begin(metadata,scope,0),'corrupt journal overwritten')
ffi.C.munmap(memory,4096)
print('PASS: thought intent SQLite durability, fork claim and draft quota ('..checks..' checks)')
