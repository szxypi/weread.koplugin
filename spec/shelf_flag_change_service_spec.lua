package.path='./?.lua;'..package.path
local C=require('weread.lib.shelf_flag_change_contract');local Task=require('weread.lib.shelf_flag_change_task')
local Service=require('weread.lib.shelf_flag_change_service');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function shelf(private) return {books={{bookId='41',title='Synthetic target',finishReading=0,secret=private}},archive={}} end
local function progress() return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=100,progress=37.5}} end
local function observed(private) return {raw=shelf(private),progress=progress(),snapshot=shelf(private)} end
local function fixture()
    local f={clock=100,frame=true,record={phase='idle',revision=0},posts=0,caches=0,starts=0}
    local settings,credentials,state=F.access();f.auth=state;f.codec=F.codec()
    f.journal={read=function() if f.corrupt then return nil,'storage' end;return F.clone(f.record) end,
        owns=function(_self,record,phase) return record.id==f.record.id and f.record.phase~='idle' and (not phase or phase==f.record.phase) end,
        begin=function(_self,metadata,_scope,revision)
            if f.fail_begin or f.record.phase~='idle' or f.record.revision~=revision then return end
            f.record={phase='prepared',revision=revision+1,id='synthetic-intent',metadata=F.clone(metadata)};return F.clone(f.record)
        end,
        finish=function(_self,record,phase)
            if f.fail_finish or record.id~=f.record.id or f.record.phase~=phase then return false end
            f.record={phase='idle',revision=f.record.revision+1};return true
        end}
    local worker={start=function(_self,task,callback) f.starts=f.starts+1;if f.reject then return false end;f.task,f.callback=task,callback;return true end,
        cancel=function() f.cancelled=true end}
    Task.preview=function()
        local plan=C.make(shelf(0),progress(),'41',true);plan.observed=observed(0);return plan
    end
    Task.inspect=function() return f.inspected or observed(0) end
    Task.run=function(_client,_settings,_selected,_input,record)
        expect(f.journal:owns(record,'prepared'),'no prepared record before worker')
        if f.unsent then return {book_id='41',kind='changed',attempted=false,observed=observed(0)} end
        f.record.phase='pending';f.posts=f.posts+1
        return {book_id='41',kind=f.unknown and 'unconfirmed' or 'confirmed',attempted=true,observed=observed(f.unknown and 0 or 1)}
    end
    f.service=Service:new{settings=settings,client=f.codec,scheduler={},journal=f.journal,credentials=credentials,worker=worker,
        now=function() return f.clock end,persist=function(snapshot)
            if f.fail_cache then return false end;f.caches=f.caches+1;f.saved=F.clone(snapshot);return true
        end}
    function f.prepare(resolve) return f.service:prepare('41',function() return f.frame end,function(plan,why) f.plan,f.reason=plan,why end,resolve) end
    function f.complete(value) local callback=f.callback;callback(value or f.task()) end
    function f.commit() return f.service:commit(f.plan,function(result,finished) f.result,f.finished=result,finished end) end
    return f
end
local f=fixture();expect(f.prepare() and f.record.phase=='idle','preview wrote intent');f.complete()
expect(f.commit() and f.record.phase=='prepared' and f.posts==0,'commit not prepared before worker');f.complete()
expect(f.finished and f.caches==1 and f.record.phase=='idle' and f.posts==1,'readback not cached before finishing')
expect(not f.commit(),'preview committed twice')
for _i,kind in ipairs({'clock','scope','view','metadata'}) do
    f=fixture();f.prepare();f.complete()
    if kind=='clock' then f.clock=221 elseif kind=='scope' then f.auth.revision=2 elseif kind=='view' then f.frame=false else f.plan.metadata.desired=false end
    expect(not f.commit() and f.posts==0 and f.record.phase=='idle','stale preview dispatched: '..kind)
end
for _i,kind in ipairs({'cache','finish','unknown'}) do
    f=fixture();f.prepare();f.complete();f.commit()
    if kind=='cache' then f.fail_cache=true elseif kind=='finish' then f.fail_finish=true else f.unknown=true end
    f.complete();expect(not f.finished and f.record.phase=='pending' and f.posts==1,'uncertain result lost pending: '..kind)
    expect(not f.prepare() and f.posts==1,'pending result permitted new write')
end
f=fixture();f.prepare();f.complete();f.commit();local callback=f.callback;f.service:cancel()
expect(f.record.phase=='idle' and f.posts==0,'prepared cancellation did not clear unsent state')
callback({book_id='41',kind='unconfirmed',attempted=true});expect(not f.result,'late cancelled callback changed UI')
f=fixture();f.prepare();f.complete();f.commit();f.task();f.service:cancel()
expect(f.record.phase=='pending' and f.posts==1,'possible dispatch was discarded by cancellation')
f=fixture();f.prepare();f.complete();f.commit();f.unsent=true;f.complete()
expect(f.finished and f.record.phase=='idle' and f.posts==0,'proven unsent state retained as sent')
f=fixture();f.prepare();f.complete();f.commit();f.task();f.service:cancel();expect(f.prepare(true),'pending read-only preparation blocked');f.complete()
f.plan.observed.snapshot.books[1].secret=1
expect(not f.commit(),'reconciliation plan dispatched')
expect(f.service:accept_current(f.plan) and f.saved.books[1].secret==0 and f.record.phase=='idle' and f.posts==1,'accept current used mutated display snapshot or wrote again')
f=fixture();f.prepare();f.complete();f.commit();f.task();f.service:cancel();f.prepare(true);f.complete();f.fail_cache=true
expect(not f.service:accept_current(f.plan) and f.record.phase=='pending','accept current cleared without cache')
for _i,kind in ipairs({'removed','unknown','position'}) do
    f=fixture();f.prepare();f.complete();f.commit();f.task();f.service:cancel();f.inspected=observed(0)
    if kind=='removed' then f.inspected.raw.books={};f.inspected.snapshot.books={}
    elseif kind=='unknown' then f.inspected.raw.books[1].secret=nil;f.inspected.snapshot.books[1].secret=nil
    else f.inspected.progress=nil end
    expect(f.prepare(true),'changed pending state not inspectable');f.complete()
    expect(f.plan and not f.plan.current_private and (kind~='removed' or not f.plan.current_present),'unknown current flag guessed')
    expect(not f.commit() and f.service:accept_current(f.plan) and f.posts==1,'read-only acceptance failed or dispatched')
end
f=fixture();f.prepare();f.complete();f.reject=true;expect(not f.commit() and f.record.phase=='idle','worker rejection leaked prepared state')
f=fixture();f.corrupt=true;expect(not f.prepare() and f.posts==0,'corrupt intent overwritten')
print('PASS: private-reading service ownership, persistence and cancellation ('..checks..' checks)')
