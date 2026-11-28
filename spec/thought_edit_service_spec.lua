package.path='./?.lua;'..package.path
local F=require('spec.helpers.thought_edit_fixture')
local C=require('weread.lib.thought_edit_contract')
local Task=require('weread.lib.thought_edit_task')
local Service=require('weread.lib.thought_edit_service')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local f={clock=100,frame=true,starts=0,posts=0,record={phase='idle',revision=0},caches=0}
    local settings,credentials,state=F.access();f.auth=state
    local client=F.codec();f.client=client
    f.input={book_id='900001',operation='edit',reference=F.row(),content='New text',draft={draft_key='key',token='version'}}
    f.snapshot=F.snapshot(client)
    f.journal={read=function() if f.corrupt then return nil,'storage' end;return F.clone(f.record) end,
        owns=function(_self,record,phase) return record.id==f.record.id and f.record.phase~='idle' and (not phase or phase==f.record.phase) end,
        begin=function(_self,metadata,_scope,revision)
            if f.record.phase~='idle' or revision~=f.record.revision or f.fail_begin then return nil end
            f.record={phase='prepared',revision=revision+1,id='synthetic-'..f.clock,metadata=F.clone(metadata)};return F.clone(f.record)
        end,
        finish=function(_self,record,phase,keep)
            if f.fail_finish or record.id~=f.record.id or f.record.phase~=phase then return false end
            f.kept=keep;f.record={phase='idle',revision=f.record.revision+1};return true
        end}
    local worker={start=function(_self,task,callback)
        f.starts=f.starts+1;if f.reject then return false elseif f.throw then error('startup') end
        f.task,f.callback=task,callback;return true
    end,cancel=function() f.cancelled=true end}
    local cache={write=function(_self,snapshot)
        if f.fail_cache then return false end;f.caches=f.caches+1;f.saved=F.clone(snapshot);return true
    end}
    Task.preview=function() if f.expired then error('my_thoughts/native_expired',0) end;return C.make(client,f.snapshot,'edit',F.row(),'New text') end
    Task.observe=function() return F.clone(f.snapshot) end
    Task.run=function(_client,_settings,_selected,_input,record)
        expect(f.journal:owns(record,'prepared'),'worker launched without prepared intent')
        if f.unsent then return {kind='changed',attempted=false} end
        f.record.phase='pending';f.posts=f.posts+1
        if not f.unknown then f.snapshot.reviews[1].content='New text' end
        return {kind=f.unknown and 'unconfirmed' or 'confirmed',snapshot=F.clone(f.snapshot),attempted=true}
    end
    f.service=Service:new{settings=settings,client=client,scheduler={},journal=f.journal,cache=cache,worker=worker,credentials=credentials,now=function() return f.clock end}
    function f.prepare(resolve)
        return f.service:prepare(f.input,function() return f.frame end,function(plan,why) f.plan,f.reason=plan,why end,resolve)
    end
    function f.complete(value) local callback=f.callback;callback(value or f.task()) end
    function f.commit() return f.service:commit(f.plan,function(result,finished) f.outcome,f.finished=result,finished end) end
    return f
end
local f=fixture();expect(f.prepare() and f.record.phase=='idle' and f.posts==0,'preview reserved or sent');f.complete()
expect(f.commit() and f.record.phase=='prepared' and f.posts==0,'commit did not durably prepare');f.complete()
expect(f.finished and f.record.phase=='idle' and f.caches==1 and f.posts==1,'confirmed snapshot not persisted before finish')
expect(not f.commit() and f.posts==1,'preview reused')
for _i,mode in ipairs({'display','clock','grant','frame'}) do
    f=fixture();f.prepare();f.complete()
    if mode=='display' then f.plan.operation='delete' elseif mode=='clock' then f.clock=221 elseif mode=='grant' then f.auth.revision=2 else f.frame=false end
    expect(not f.commit() and f.record.phase=='idle','stale/changed preview dispatched: '..mode)
end
f=fixture();f.prepare();f.input.content='Mutated';f.input.reference.content='Mutated';f.complete()
expect(f.service.preview_job.input.content=='New text' and f.service.preview_job.input.reference.content==F.row().content,'caller mutated frozen input')
f=fixture();f.prepare();f.complete();f.commit();local callback=f.callback;f.service:cancel()
expect(f.record.phase=='idle' and f.posts==0,'cancel did not clear proven unsent preparation');callback({kind='unconfirmed'})
expect(not f.outcome,'cancelled completion callback escaped')
f=fixture();f.prepare();f.complete();f.commit();local result=f.task();f.service:cancel()
expect(f.record.phase=='pending' and f.posts==1,'cancel forgot possible dispatch')
expect(not f.prepare() and f.prepare(true),'pending operation replayed or readonly recovery blocked');f.complete()
expect(f.plan.confirmed and f.service:resolve(f.plan) and f.record.phase=='idle' and f.caches==1,'read-only confirmed recovery failed')
f.callback(result);expect(f.posts==1 and f.record.phase=='idle','old completion changed recovered state')
for _i,mode in ipairs({'unknown','cache','finish'}) do
    f=fixture();f.prepare();f.complete();f.commit()
    if mode=='unknown' then f.unknown=true elseif mode=='cache' then f.fail_cache=true else f.fail_finish=true end
    f.complete();expect(not f.finished and f.record.phase=='pending' and f.posts==1,'uncertainty discarded: '..mode)
end
f=fixture();f.prepare();f.complete();f.commit();f.unknown=true;f.complete();f.prepare(true);f.complete()
expect(not f.plan.confirmed and not f.service:resolve(f.plan),'unconfirmed operation auto-accepted')
expect(f.service:resolve(f.plan,true) and f.kept and f.posts==1,'explicit current-state acceptance lost draft or sent a write')
for _i,mode in ipairs({'unsent','reject','throw'}) do
    f=fixture();f.prepare();f.complete()
    if mode=='unsent' then f.unsent=true;f.commit();f.complete();expect(f.finished and f.record.phase=='idle','unsent result stuck')
    else f[mode]=true;expect(not f.commit() and f.record.phase=='idle' and f.posts==0,'failed startup stranded unsent intent') end
end
f=fixture();f.expired=true;f.prepare();f.complete();expect(f.reason=='native_expired' and f.record.phase=='idle','expiry reserved or retried')
f=fixture();f.corrupt=true;expect(not f.prepare() and f.starts==0,'corrupt journal overwritten')
f=fixture();f.auth.pending=true;expect(not f.prepare() and f.starts==0,'unknown renewal dispatched')
print('PASS: thought preview lifetimes, durable completion and no replay ('..checks..' checks)')
