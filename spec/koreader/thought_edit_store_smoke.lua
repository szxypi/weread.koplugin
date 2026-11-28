-- Real SQLite, fork races, interrupted dispatch state and bounded drafts.
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local lfs=require('libs/libkoreader-lfs')
local root=assert(arg[2]);assert(root:match('^/dev/shm/'));assert(lfs.mkdir(root))
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
pcall(ffi.cdef,'int fork(void); int waitpid(int, int *, int); void _exit(int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local account='900000';local library=require('weread.lib.library_db'):new{data_dir=root,get=function(_self,key,default)
    return key=='account' and {user_vid=account} or default end}
local F=require('spec.helpers.thought_edit_fixture');local C=require('weread.lib.thought_edit_contract')
local Store=require('weread.lib.thought_edit_store');local store=Store:new(library,codec)
local metadata=C.make(codec,F.snapshot(codec),'edit',F.row(),'New text').metadata
local scope={vid='900000',epoch=1};local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local absent,why=store:draft(Store.draft_key('900001','edit','synthetic-note'))
expect(not absent and not why and #assert(store:drafts())==0 and not lfs.attributes(library:databasePath()),
    'reading drafts on a new profile created a database or reported corruption')
local empty_db=assert(library:open());empty_db:close()
expect(#assert(store:drafts())==0,'account database without a drafts table was not treated as empty')
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
local imported_draft=assert(store:save_draft('CB_Synthetic','create','synthetic-mark',C.row_hash(F.row()),'Imported draft'))
expect(store:draft(imported_draft.draft_key).content=='Imported draft','imported draft not durable')
account='900099';expect(not store:draft(imported_draft.draft_key),'imported draft leaked between accounts');account='900000'
expect(store:delete_draft(imported_draft),'imported draft could not be removed')
draft=assert(store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Draft old'))
local previous=draft;draft=assert(store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Draft replacement'))
expect(not store:delete_draft(previous) and store:draft(draft.draft_key).content=='Draft replacement','old draft callback deleted replacement')
expect(not store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Unexpected create',false),
    'expected-absent save overwrote an existing draft')
expect(not store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Stale edit',previous.token),
    'stale draft token overwrote a newer version')
expect(store:draft(draft.draft_key).token==draft.token,'rejected save changed the draft')
counter[0],counter[1]=0,0
local function save_race()
    while counter[1]==0 do require('socket').sleep(.001) end
    if store:save_draft('900001','edit','synthetic-note',C.row_hash(F.row()),'Concurrent edit',draft.token) then counter[0]=counter[0]+1 end
end
a=fork(save_race);b=fork(save_race);counter[1]=1;reap(a);reap(b)
local current=assert(store:draft(draft.draft_key))
expect(counter[0]==1 and current.token~=draft.token and current.content=='Concurrent edit','draft compare-and-save was not exclusive')
draft=current
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
library.open=function() error('read opened a write connection') end
local content_check=C.valid_content;local validated=0
C.valid_content=function(value) validated=validated+1;return content_check(value) end
expect(store:draft(replacement.draft_key).token==replacement.token and validated==1,'exact read validated unrelated drafts')
validated=0
expect(#assert(store:drafts())==16 and validated==16,'draft list skipped validation or opened a write connection')
validated=0
local previews=assert(store:draft_previews())
expect(#previews==16 and validated==16 and previews[1].draft_key==Store.draft_key('900001','edit','synthetic-2'),
    'draft previews skipped validation or changed ordering')
expect(previews[1].preview=='Replacement at quota' and previews[1].content==nil and previews[1].base_hash==nil,
    'draft previews transferred editor data')
C.valid_content=content_check;library.open=open
local writer=assert(library:open())
writer:exec('BEGIN IMMEDIATE')
local pending=writer:prepare('UPDATE thought_drafts SET content=? WHERE draft_key=?')
pending:bind('Uncommitted draft',replacement.draft_key):step();pending:close()
expect(store:draft(replacement.draft_key).content==replacement.content,'read picked up an uncommitted replacement')
writer:exec('ROLLBACK');writer:close()
local other_key=Store.draft_key('900001','edit','synthetic-2')
local function update(sql,...)
    local db=assert(library:open());local stmt=db:prepare(sql);stmt:bind(...):step();stmt:close();db:close()
end
update('UPDATE thought_drafts SET token=? WHERE draft_key=?','invalid',other_key)
local corrupt,corruption=store:draft(other_key)
expect(not corrupt and corruption=='storage','corrupt targeted draft was treated as absent')
expect(not store:drafts() and store:draft(replacement.draft_key).token==replacement.token,
    'corrupt unrelated draft blocked a valid exact read or was listed')
expect(not store:draft_previews(),'corrupt draft was exposed in the preview list')
account='900097'
local duplicates=assert(library:open())
duplicates:exec([[CREATE TABLE thought_drafts (draft_key,book_id,operation,reference_id,base_hash,content,token,serial)]])
local insert=duplicates:prepare('INSERT INTO thought_drafts VALUES(?,?,?,?,?,?,?,?)')
for _=1,2 do
    insert:reset():bind(replacement.draft_key,replacement.book_id,replacement.operation,replacement.reference_id,
        replacement.base_hash,replacement.content,replacement.token,replacement.serial):step()
end
insert:close();duplicates:close()
absent,why=store:draft(replacement.draft_key)
expect(not absent and why=='storage','exact read accepted duplicate draft identities')
account='900098'
local invalid_db=assert(io.open(library:databasePath(),'wb'));invalid_db:write('Not SQLite');invalid_db:close()
absent,why=store:draft(replacement.draft_key)
expect(not absent and why=='storage','an unreadable database was treated as empty')
account='900000'
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
-- Highlight journal uses the same FULL/CAS implementation with a separate
-- validated contract and row. A fresh process cannot reclaim its dispatch.
local thought_store=store
local MF=require('spec.helpers.mark_edit_fixture');local MC=require('weread.lib.mark_edit_contract')
local MS=require('weread.lib.mark_edit_service');store=MS.new_journal(library,codec)
local mark_plan=MC.make(codec,MF.snapshot(codec),'create',MF.reference(),{bookId='900001',version=77})
record=assert(store:begin(mark_plan.metadata,scope,0));counter[0],counter[1]=0,0
a=fork(race);b=fork(race);counter[1]=1;reap(a);reap(b)
expect(counter[0]==1 and store:read().phase=='pending','highlight claim not exclusive')
expect(thought_store:read().phase=='idle','highlight intent replaced thought journal')
local mark_fresh=MS.new_journal(library,codec)
expect(mark_fresh:owns(record,'pending') and not mark_fresh:claim(record),'fresh highlight process replayed')
expect(mark_fresh:finish(record,'pending'),'highlight reconciliation failed')
local mark_db=assert(library:open());local mark_raw=mark_db:rowexec('SELECT payload FROM mark_write_state');mark_db:close()
expect(not mark_raw:find('合成新划线',1,true),'highlight intent retained quote')
store=thought_store
local db=assert(library:open());local row=db:rowexec('SELECT payload FROM thought_write_state')
expect(not row:find('New text',1,true) and not row:find('合成引用',1,true),'journal stored text')
db:exec("UPDATE thought_write_state SET payload='{}' WHERE id=1");db:close()
expect(not store:read() and not store:begin(metadata,scope,0),'corrupt journal overwritten')
ffi.C.munmap(memory,4096)
print('PASS: thought intent SQLite durability, fork claim and draft quota ('..checks..' checks)')
