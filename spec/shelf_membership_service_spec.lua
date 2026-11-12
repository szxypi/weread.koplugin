package.path='./?.lua;'..package.path
package.preload['luasettings']=function() return {} end
local Service=require('weread.lib.shelf_membership_service')
local Task=require('weread.lib.shelf_membership_write')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function snapshot(present)
    local books={{bookId='41',title='Other'}};if present then books[#books+1]={bookId='42',title='Target'} end
    return {books=books,archive={}}
end
local function fixture()
    local f={valid=true,frame=true,revision=1,clock=100,starts=0,posts=0,cancels=0,record={revision=0,phase='idle'}}
    local credentials={vid='900000',accessToken='synthetic-access'}
    local settings={get_auth_scope=function() return {vid='900000',epoch=1} end,auth_scope_matches=function() return f.valid end}
    local store={read=function() return credentials,f.revision,nil,f.auth_pending end}
    local journal={read=function() if f.corrupt then return nil,'storage' end;return f.record end,
        begin=function(_self,_scope,id,op)
            if f.fail_begin or f.record.phase=='pending' then return nil end
            f.record={revision=f.record.revision+1,phase='pending',id='nonce'..f.clock,book_id=id,operation=op,epoch=1};return f.record
        end,owns=function(_self,_scope,receipt) return receipt==f.record and f.record.phase=='pending' end,
        finish=function(_self,_scope,receipt)
            if f.fail_finish or receipt~=f.record then return false end
            f.record={revision=f.record.revision+1,phase='idle'};return true
        end}
    local worker={start=function(_self,task,callback)
        f.starts=f.starts+1
        if f.reject then return false end
        if f.throw then error('worker startup failed') end
        f.task,f.callback=task,callback
        if f.starts>1 then expect(f.record.phase=='pending','worker started before durable intent') end
        return true
    end,cancel=function() f.cancels=f.cancels+1 end}
    Task.fetch=function() return snapshot(false) end
    Task.run=function(_client,_settings,_access,input,owns)
        expect(owns() and input.book_id=='42' and input.operation=='add','worker lost journal/target binding')
        f.posts=f.posts+1
        return f.result or {book_id='42',operation='add',attempted=true,confirmed=true,acknowledged=true,kind='confirmed',snapshot=snapshot(true)}
    end
    f.options={settings=settings,client={},scheduler={},journal=journal,store=store,worker=worker,now=function() return f.clock end}
    f.service=Service:new(f.options)
    function f.prepare(resolve)
        return f.service:prepare('42',function() return f.frame end,function(plan,reason,selected) f.plan,f.reason,f.selected=plan,reason,selected end,resolve)
    end
    function f.complete(value) local callback=f.callback;callback(value or f.task()) end
    function f.commit()
        return f.service:commit(f.plan,function(result,finished,selected) f.outcome,f.finished,f.selected=result,finished,selected end)
    end
    return f
end
local f=fixture();expect(f.prepare() and not f.plan and f.posts==0,'preview performed a write');f.complete()
expect(f.plan and not f.plan.before and f.commit() and f.record.phase=='pending','valid explicit commit did not reserve')
f.complete();expect(f.finished and f.outcome.kind=='confirmed' and f.record.phase=='idle' and f.posts==1,'confirmed readback did not finish one write')
expect(not f.commit() and f.posts==1,'consumed preview was replayed')
f=fixture();f.prepare();f.complete();f.plan.operation='remove'
expect(not f.commit() and f.record.phase=='idle','changed displayed action bypassed preview binding')
for _i,mode in ipairs({'frame','grant','clock','pending_auth'}) do
    f=fixture();f.prepare();f.complete()
    if mode=='frame' then f.frame=false elseif mode=='grant' then f.revision=2 elseif mode=='clock' then f.clock=221 else f.auth_pending=true;f.revision=2 end
    expect(not f.commit() and f.record.phase=='idle','stale preview reserved a write: '..mode)
end
f=fixture();f.prepare();f.revision=2;f.complete()
expect(not f.service.job and f.reason=='session_changed','changed grant stranded the preview consumer')
for _i,mode in ipairs({'nil','bad_snapshot','noack','foreign'}) do
    f=fixture();f.prepare();f.complete();f.commit()
    local r={book_id='42',operation='add',attempted=true,confirmed=true,acknowledged=true,kind='confirmed',snapshot=snapshot(true)}
    if mode=='nil' then r={} elseif mode=='bad_snapshot' then r.snapshot={} elseif mode=='noack' then r.acknowledged=false else r.book_id='43' end
    f.complete(r);expect(not f.finished and f.record.phase=='pending','invalid completion cleared durable intent: '..mode)
end
f=fixture();f.prepare();f.complete();f.commit();local old=f.callback;f.service:cancel()
f.service=Service:new(f.options)
local started,why=f.prepare();expect(not started and why=='pending' and f.service:pending(),'fresh service replayed an uncertain operation')
expect(f.prepare(true),'pending readonly check could not start');f.complete()
expect(f.plan.resolving and f.service:accept_current(f.plan) and f.record.phase=='idle' and f.posts==0,'explicit readonly acceptance failed')
f.starts=0;f.prepare();f.complete();f.commit();local current=f.record
old({book_id='42',operation='add',attempted=false,kind='unavailable'})
expect(f.record==current,'old callback cleared newer intent')
f=fixture();f.prepare();f.complete();f.commit();f.revision=2;f.complete({})
expect(not f.service.job and not f.finished and f.outcome.kind=='unconfirmed' and f.record.phase=='pending','changed grant hid uncertainty or stranded consumer')
for _i,mode in ipairs({'reserve','finish','startup_false','startup_throw'}) do
    f=fixture();f.prepare();f.complete()
    if mode=='reserve' then f.fail_begin=true elseif mode=='finish' then f.fail_finish=true elseif mode=='startup_false' then f.reject=true else f.throw=true end
    local sent=f.commit()
    if mode=='finish' then f.complete();expect(not f.finished and f.record.phase=='pending','failed journal completion was treated as durable')
    elseif mode=='reserve' then expect(not sent and f.starts==1 and f.posts==0,'failed reservation reached worker')
    else expect(not sent and f.record.phase=='pending' and f.posts==0,'failed worker start lost conservative journal') end
end
f=fixture();f.auth_pending=true
expect(not f.prepare() and f.starts==0,'unknown renewal was used for a data write')
f=fixture();f.corrupt=true
expect(not f.prepare() and f.starts==0,'corrupt journal was overwritten')
f=fixture();Task.fetch=function() error('native_auth/shelf/http_401',0) end
f.prepare();f.complete()
expect(f.reason=='native_expired' and f.selected and not f.service.job and not f.plan and f.record.phase=='idle',
    'preview expiry lost the captured grant or reserved a data change')
for _i,failed_finish in ipairs({false,true}) do
    f=fixture();f.prepare();f.complete();f.commit();f.fail_finish=failed_finish
    f.complete({book_id='42',operation='add',attempted=false,kind='login'})
    expect(f.finished==not failed_finish and f.selected and (f.record.phase=='idle')==not failed_finish,
        'proven-unsent expiry requires durable journal completion before recovery')
end
print(('shelf_membership_service_spec: %d checks'):format(checks))
