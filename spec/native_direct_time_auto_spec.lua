package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local Crypto=require('weread.lib.crypto')
local Auto=require('weread.lib.native_direct_time_auto')
local checks=0;local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    local f={now=1000,online=true,visible=true,enabled=true,automatic=true,jobs={},work={},messages={}}
    local scope={vid='123',epoch=1};local account=Crypto.sha256_hex('weread-library:123'):sub(1,20)
    local document={file='/fixture/native-reader-v1/account/book/chapter.epub'}
    local reader={document=document,statistics={}}
    local settings={data_dir='/fixture',get=function(_,key)
        if key=='offline_time' then return {enabled=f.enabled,auto_native=f.automatic} end
        return {}
    end,get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return f.scope_valid~=false and value==scope end}
    local host={settings=settings,ui=reader,_reader_session_gen=1,client={},readtime_coverage={},
        library_db={accountKey=function() return f.other_account and string.rep('f',20) or account end},
        isNetworkConnected=function() return f.online end,showTransientInfo=function(_,message) f.messages[#f.messages+1]=message end}
    host.offline_time={active={account=account,book_id='42',document=document,native_time_file_id=string.rep('a',64)}}
    local scheduler={scheduleIn=function(_,seconds,fn) f.jobs[fn]=f.now+seconds end,
        unschedule=function(_,fn) f.jobs[fn]=nil end}
    local worker={start=function(_,task,callback) f.work[#f.work+1]={task=task,callback=callback};return true end,
        cancel=function() f.cancelled=(f.cancelled or 0)+1 end}
    local service={start=function(_,mode,owner,selection,refs,guard,callback)
        expect(mode=='send' and owner==account and selection.current_day and refs[1].kind=='native_direct' and guard(),
            'invalid automatic dispatch')
        f.starts=(f.starts or 0)+1;f.guard=guard;f.callback=callback
        if f.reject then return false,f.reject end
        return true
    end,cancel=function() f.service_cancelled=(f.service_cancelled or 0)+1 end}
    local selection={book_id='42',file_id=string.rep('a',64),native_direct=true,current_day=true}
    local ref={kind='native_direct',file='/fixture/file.epub',chapter_uid='7',source_sha256=string.rep('b',64)}
    local options={scheduler=scheduler,now=function() return f.now end,visible=function() return f.visible end,
        worker_factory=function() return worker end,service_factory=function() return service end,
        select=function(_,_,book)
            expect(book=='42');if f.pending then return {pending=true} end
            if f.empty then return {selection=false} end;return {selection=selection}
        end,
        scan=function(_,_,selected,cursor,prior)
            expect(selected==selection)
            if cursor==1 then return {kind='more',cursor=33,prior={stamp='fixture'}} end
            expect(cursor==33 and prior.stamp=='fixture');return {kind='found',reference=ref}
        end}
    f.host,f.options,f.selection,f.ref=host,options,selection,ref
    function f.start(reset) return Auto.start(host,reset,options) end
    function f.advance(seconds)
        f.now=f.now+seconds;local due={}
        for fn,at in pairs(f.jobs) do if at<=f.now then due[#due+1]=fn end end
        for _,fn in ipairs(due) do f.jobs[fn]=nil;fn() end
    end
    function f.deliver(index)
        local item=assert(f.work[index or #f.work]);local ok,value=pcall(item.task)
        item.callback(ok and value or nil)
    end
    return f
end
local f=fixture();f.automatic=false;expect(not f.start() and not next(f.jobs),'disabled automatic sync scheduled')
f.automatic=true;expect(f.start() and next(f.jobs),'enabled automatic sync did not schedule')
f.advance(299);expect(#f.work==0 and not f.starts,'automatic sync ran early')
f.advance(1);expect(#f.work==1 and not f.starts,'timer did not begin local selection')
f.deliver();f.deliver();f.deliver();expect(f.starts==1 and f.guard(),'selection/source scan did not reach service')
f.callback({kind='confirmed'});expect(next(f.jobs) and not f.host._native_auto_time_blocked,'confirmed batch did not reschedule')
f.empty=true;f.advance(300);f.deliver();expect(f.starts==1 and next(f.jobs),'empty batch sent or stopped schedule')
f.empty=false;f.advance(300);f.deliver();f.deliver();f.deliver();expect(f.starts==2)
f.callback({kind='unconfirmed'});expect(not f.host._native_auto_time and f.host._native_auto_time_blocked and #f.messages==1,
    'uncertain result did not stop automatic sync')
expect(not f.start() and not next(f.jobs),'uncertain result was automatically retried')
expect(f.start(true),'explicit reset did not rearm')
f=fixture();f.start();f.advance(300);f.deliver();f.deliver();f.deliver()
f.callback({kind='position_required'})
expect(f.host._native_auto_time_blocked and f.messages[1]=='Sync this page to the cloud before transferring this book’s saved reading time.'
    and not next(f.jobs),'unstarted book did not stop automatic transfer with useful guidance')
f=fixture();f.start();f.online=false;f.advance(300);expect(not f.starts and not f.host._native_auto_time,'offline timer dispatched')
f=fixture();f.start();f.visible=false;f.advance(300);expect(#f.work==0 and next(f.jobs),'covered reader started work')
f.visible=true;f.host.offline_time.active=nil;f.advance(300);expect(#f.work==0 and next(f.jobs),'inactive collector started work')
f=fixture();f.start();f.advance(300);local stale=f.work[1];Auto.cancel(f.host);stale.callback(stale.task())
expect(not f.starts and not f.host._native_auto_time,'cancelled selection dispatched')
f=fixture();f.start();f.advance(300);f.other_account=true;f.deliver()
expect(not f.starts and not f.host._native_auto_time,'account change dispatched')
f=fixture();f.pending=true;f.start();f.advance(300);f.deliver()
expect(not f.starts and f.host._native_auto_time_blocked and #f.messages==1,'unfinished transfer did not stop automatic sync')
f=fixture();f.start();f.advance(300);f.deliver();f.deliver();f.deliver()
f.host._reader_session_gen=2;expect(not f.guard(),'new reader accepted an old service guard')
Auto.cancel(f.host);f.callback({kind='confirmed'});expect(not next(f.jobs),'late service result restarted old session')
f=fixture();f.reject='busy';f.start();f.advance(300);f.deliver();f.deliver();f.deliver()
expect(next(f.jobs) and not f.host._native_auto_time_blocked,'busy writer disabled future sync')
f=fixture();f.reject='pending';f.start();f.advance(300);f.deliver();f.deliver();f.deliver()
expect(f.host._native_auto_time_blocked and not next(f.jobs),'pending journal did not stop automatic sync')
f=fixture();f.options.scan=function() return {kind='ambiguous'} end
f.start();f.advance(300);f.deliver();f.deliver()
expect(not f.starts and f.host._native_auto_time_blocked,'ambiguous chapter reached transport')
f=fixture();f.options.select=function() error('synthetic failure') end
f.start();f.advance(300);f.deliver();expect(not f.starts and f.host._native_auto_time_blocked,'failed selection was retried')
f=fixture();f.start();local old_timer=next(f.jobs);Auto.cancel(f.host);old_timer()
expect(not f.starts and #f.work==0 and not next(f.jobs),'cancelled timer restarted work')
f=fixture();f.start();old_timer=next(f.jobs);f.jobs[old_timer]=nil;f.now=900;old_timer()
expect(#f.work==0 and next(f.jobs),'backward clock did not restart the interval')
print('PASS: native automatic reading time stays session-bound and single-shot ('..checks..' checks)')
