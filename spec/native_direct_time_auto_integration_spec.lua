package.path='./?.lua;./?/init.lua;'..package.path
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local Auto=require('weread.lib.native_direct_time_auto')
local Service=require('weread.lib.readtime_transfer_service')
local Fixture=require('spec.helpers.readtime_transfer_fixture')
local Signing=require('weread.lib.readtime_protocol');local original_zone=Signing.time_zone
Signing.time_zone=function() return '+08:00' end
local roots,checks={},0
local function expect(value,message) checks=checks+1;assert(value,message or 'integration check failed') end
local function fixture(mode)
    local f=Fixture.new(mode,expect,roots,false,{version_source='native_direct',current_day=true})
    local old_get=f.settings.get
    f.settings.data_dir=f.root
    f.settings.get=function(self,key,default)
        if key=='offline_time' then return {enabled=true,auto_native=true} end
        return old_get(self,key,default)
    end
    local document={file=f.root..'/native-reader-v1/account/book/chapter.epub'}
    local reader={document=document,statistics={}}
    local host={settings=f.settings,client=f.client,ui=reader,_reader_session_gen=1,readtime_coverage=f.coverage,
        library_db={accountKey=function() return f.account end},isNetworkConnected=function() return true end,
        showTransientInfo=function() f.notices=(f.notices or 0)+1 end}
    host.offline_time={store=f.ledger,active={book_id=f.book_id,account=f.account,document=document,native_time_file_id=f.file_id}}
    local scheduler={scheduleIn=function(_,seconds,task) f.tasks=f.tasks or {};f.tasks[task]=f.clock+seconds end,
        unschedule=function(_,task) if f.tasks then f.tasks[task]=nil end end}
    local jobs={}
    local function worker() return {start=function(_,task,callback)
        jobs[#jobs+1]={task=task,callback=callback};return true end,cancel=function() end} end
    local reference={kind='native_direct',file='/synthetic.epub',chapter_uid='7',source_sha256=string.rep('b',64)}
    f.options.observe_source=function(_client,_web,selection,_refs,previous)
        if f.mode=='source_changed' and previous and f.posts>0 then error('changed') end
        return {kind='native_direct',ref=reference,account=f.account,file_id=selection.file_id}
    end
    local auto_options={interval=1,scheduler=scheduler,now=function() return f.clock end,visible=function() return true end,
        worker_factory=worker,scan=function() return {kind='found',reference=reference} end,
        service_factory=function()
            return Service:new{settings=f.settings,client=f.client,journal=f.journal,scheduler=scheduler,worker=worker(),
                credentials=f.native.store,now=function() return f.clock end,task_options=f.options,
                guard_factory=function()
                    local gate={open=true};function gate:valid() return self.open end;function gate:close() self.open=false end
                    return gate
                end,acquire=function() return function() end end}
        end}
    f.host,f.jobs=host,jobs
    function f.tick(seconds)
        f.clock=f.clock+seconds;local due={}
        for task,at in pairs(f.tasks or {}) do if at<=f.clock then due[#due+1]=task end end
        for _,task in ipairs(due) do f.tasks[task]=nil;task() end
    end
    function f.deliver(index)
        local job=assert(jobs[index],'missing job '..index..' after '..#jobs..' jobs')
        local ok,value=pcall(job.task);job.callback(ok and value or nil)
    end
    expect(Auto.start(host,true,auto_options),'could not arm automatic sync')
    return f
end
local f=fixture();f.tick(1);f.deliver(1);f.deliver(2);f.deliver(3)
expect(f.posts==1 and f.ledger:summary(f.account).confirmed==2 and not f.journal:pending(f.account),
    'automatic send did not independently settle the captured time')
f.tick(1);f.deliver(4);expect(f.posts==1,'settled time was sent twice')
Auto.cancel(f.host)
f=fixture('lost');f.tick(1);f.deliver(1);f.deliver(2);f.deliver(3)
expect(f.posts==1 and f.host._native_auto_time_blocked and f.journal:pending(f.account),
    'lost acknowledgment did not block automatic sync')
expect(not Auto.start(f.host) and f.posts==1,'lost acknowledgment was retried')
f=fixture();f.tick(1);f.deliver(1);f.state.valid=false;f.deliver(2)
expect(f.posts==0 and not f.host._native_auto_time,'account change did not cancel pending source scan')
Signing.time_zone=original_zone
for _,root in ipairs(roots) do os.execute('rm -rf '..string.format('%q',root)) end
print('PASS: automatic native time uses production journal, task and readback ('..checks..' checks)')
