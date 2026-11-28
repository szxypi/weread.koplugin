package.path='./?.lua;'..package.path
local C=require('weread.lib.shelf_flag_change_contract');local Task=require('weread.lib.shelf_flag_change_task')
local Service=require('weread.lib.shelf_flag_change_service');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(value,label)checks=checks+1;assert(value,label)end
local function shelf(pin)
    local row={bookId='41',title='Synthetic',finishReading=0,secret=0};if pin~=nil then row.isTop=pin end
    return {books={row},archive={}}
end
local function progress()return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=100,progress=37.5}}end
local function observed(pin)return {raw=shelf(pin),progress=progress(),snapshot=shelf(pin)}end
local function fixture(before)
    local f={clock=100,frame=true,record={phase='idle',revision=0},posts=0,caches=0,before=before}
    local settings,credentials,state=F.access();f.auth=state;f.codec=F.codec()
    f.journal={read=function()return F.clone(f.record)end,
        owns=function(_self,record,phase)return record.id==f.record.id and f.record.phase~='idle' and (not phase or f.record.phase==phase)end,
        begin=function(_self,metadata,_scope,revision)
            if f.record.phase~='idle' or f.record.revision~=revision then return end
            f.record={phase='prepared',revision=revision+1,id='synthetic-intent',metadata=F.clone(metadata)};return F.clone(f.record)
        end,
        finish=function(_self,record,phase)
            if record.id~=f.record.id or f.record.phase~=phase then return false end
            f.record={phase='idle',revision=f.record.revision+1};return true
        end}
    local worker={start=function(_self,task,callback)f.task,f.callback=task,callback;return true end,cancel=function()end}
    Task.preview=function(_client,_settings,_selected,id,desired,kind)
        expect(kind=='pinned','wrong plan kind')
        if desired==nil then desired=f.before~=1 end
        local plan=C.make_pin(shelf(f.before),progress(),id,desired);plan.observed=observed(f.before);return plan
    end
    Task.inspect=function()return observed(f.after)end
    Task.run=function(_client,_settings,_selected,_input,record)
        expect(f.journal:owns(record,'prepared'),'request not journaled');f.record.phase='pending';f.posts=f.posts+1
        return {book_id='41',kind=f.unknown and 'unconfirmed' or 'confirmed',attempted=true,observed=observed(f.after)}
    end
    f.service=Service:new{settings=settings,client=f.codec,scheduler={},journal=f.journal,credentials=credentials,worker=worker,
        now=function()return f.clock end,persist=function(snapshot)if f.fail_cache then return false end;f.caches=f.caches+1;f.saved=F.clone(snapshot);return true end}
    function f.prepare(resolve,kind)return f.service:prepare('41',function()return f.frame end,function(plan,why)f.plan,f.reason=plan,why end,resolve,kind or 'pinned')end
    function f.complete()local cb=f.callback;cb(f.task())end
    function f.commit()return f.service:commit(f.plan,function(result,finished)f.result,f.finished=result,finished end)end
    return f
end
local f=fixture(nil);f.after=1
expect(f.prepare() and f.record.phase=='idle','preview wrote intent');f.complete()
expect(f.plan.metadata.before=='missing' and f.plan.metadata.desired,'preview inferred old pin')
expect(f.commit() and f.record.phase=='prepared' and f.posts==0,'commit did not reserve first');f.complete()
expect(f.finished and f.record.phase=='idle' and f.posts==1 and f.caches==1,'pin not cached and finished')
expect(not f.commit(),'old preview reused')
f=fixture(1);f.after=nil;f.prepare();f.complete();expect(not f.plan.metadata.desired,'pinned preview did not select unpin')
f.commit();f.complete();expect(f.finished and f.record.phase=='idle' and f.posts==1,'observed unpin not finalized')
f=fixture(nil);f.after=1;f.prepare();f.complete();f.commit();f.unknown=true;f.complete()
expect(not f.finished and f.record.phase=='pending' and f.posts==1,'ambiguous write lost pending')
expect(not f.prepare(false,'private'),'pending pin allowed private write')
f.after=nil;expect(f.prepare(true,'private'),'pin pending could not be inspected');f.complete()
expect(f.plan.metadata.kind=='pinned' and f.plan.current_pinned==nil and f.plan.current_present,'pending missing state guessed')
expect(f.service:accept_current(f.plan) and f.record.phase=='idle' and f.posts==1,'pending inspection dispatched or failed')
f=fixture(nil);f.after=1;f.prepare();f.complete();f.commit();f.fail_cache=true;f.complete()
expect(not f.finished and f.record.phase=='pending' and f.posts==1,'failed cache cleared pending')
f=fixture(nil);f.after=1;f.prepare();f.complete();f.frame=false
expect(not f.commit() and f.posts==0,'stale page dispatched')
print('PASS: cloud pin service and recovery ('..checks..' checks)')
