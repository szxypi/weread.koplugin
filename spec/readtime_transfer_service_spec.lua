package.path='./?.lua;./?/init.lua;'..package.path
local Service=require('weread.lib.readtime_transfer_service')
local Lease=require('weread.lib.readtime_transfer_lease')
local F=require('spec.helpers.readtime_transfer_fixture')
local Signing=require('weread.lib.readtime_protocol');local zone=Signing.time_zone;Signing.time_zone=function() return '+08:00' end
local roots,n={},0;local function expect(v,why) n=n+1;assert(v,why or ('check '..n)) end
local real=os.getenv('WEREAD_REAL_RUNTIME')=='1'
local H=real and {connect=require('lua-ljsqlite3/init').open} or require('spec.helpers.annotation_test_store')
local function fixture(mode)
    local f=F.new(mode,expect,roots);f.valid=true;f.releases=0;f.guard_reads=0
    local scheduled={};f.scheduled=scheduled;f.scheduler={scheduleIn=function(_s,_delay,fn) scheduled[fn]=true end,unschedule=function(_s,fn) scheduled[fn]=nil end}
    f.worker={start=function(self,task,callback) self.task,self.callback=task,callback;return not f.reject end,
        cancel=function(self) expect(not f.gate.active,'worker killed before dispatch invalidation');self.task=nil end}
    f.gate={active=true,valid=function(self) return self.active end,close=function(self) self.active=false end}
    f.host={library_db={accountKey=function() return f.account end,open=function() return H.connect(f.root..'/library.db') end},client=f.client}
    f.host.read_report={task={},stop=function(self) expect(self.offline_time_transfer~=nil);self.task=nil;f.stops=(f.stops or 0)+1 end,
        start=function(self) expect(not self.offline_time_transfer);self.task={};f.restarts=(f.restarts or 0)+1 end}
    f.host.progress_sync={interval={task={},halt=function(self) self.task=nil;f.halts=(f.halts or 0)+1 end,
        refresh=function(self) expect(not f.host.progress_sync.offline_time_transfer);self.task={};f.refreshes=(f.refreshes or 0)+1 end}}
    f.guard=function() f.guard_reads=f.guard_reads+1;expect(not f.in_child,'parent view guard copied into child');return f.valid end
    f.service=Service:new{settings=f.settings,client=f.client,journal=f.journal,credentials=f.native.store,scheduler=f.scheduler,
        worker=f.worker,now=function() return f.clock end,task_options=f.options,guard_factory=function() return f.gate end,
        acquire=function(book) return Lease.acquire(f.host,book,f.guard) end}
    function f.start(operation,input)
        return f.service:start(operation or 'send',f.account,input or f.selection,{},f.guard,function(value) f.result=value end)
    end
    function f.deliver()
        f.in_child=true;local ok,value=pcall(f.worker.task);f.in_child=false
        f.worker.callback(ok and value or nil)
    end
    return f
end
local f=fixture();expect(f.start());expect(not f.host.read_report.task and f.host.progress_sync.offline_time_transfer)
local logger=require('weread.lib.logger');if not logger.scoped then logger.scoped=function() return logger end end
local Report=require('weread.lib.read_report')
local report=f.host.read_report
expect(Report.maybe_start(report,'reader_open')==false)
expect(Report.start(report,'reader_open')==false)
expect(Report.report_once(setmetatable(report,{__index=Report}))==false)
local allowed,blocked_result=Report.upload_position(report,'42',{},0)
expect(allowed==false and blocked_result.error_kind=='busy')
expect(require('weread.lib.progress_sync')._upload_snapshot(f.host.progress_sync,{book_id='42'},'manual_sync',true)==false)
local interval=require('weread.lib.progress_interval'):new{sync=f.host.progress_sync,scheduler=f.scheduler}
expect(interval:_eligible()==false and f.posts==0,'another writer ran while the transfer held its lease')
f.deliver();expect(f.result.kind=='confirmed' and f.posts==1 and f.ledger:summary(f.account).confirmed==2)
expect(f.restarts==1 and f.refreshes==1 and not f.host._offline_time_transfer_lock and not f.service.job)
f=fixture();f.options.observe_source=function() error('readtime_source/format') end
expect(f.start());f.deliver()
expect(f.result.kind=='unsupported_source' and f.posts==0 and f.ledger:summary(f.account).pending==2)
f=fixture();expect(f.start());f.worker.callback({kind='position_required'})
expect(f.result.kind=='position_required' and f.posts==0 and f.ledger:summary(f.account).pending==2
    and not f.host._offline_time_transfer_lock,'first-position guidance was discarded or retained its lease')
-- Refuse an active writer, without abandoning its job, even before a claim.
for _i,busy in ipairs({'report','preparation','sync','source','native_position','position'}) do
    f=fixture()
    if busy=='report' then f.host.read_report.job={}
    elseif busy=='preparation' then f.host.read_report.preparation={}
    elseif busy=='sync' then f.host.progress_sync.uploading=true
    elseif busy=='source' then f.host.source_upload={job={}}
    elseif busy=='native_position' then f.host._native_direct_position={}
    else
        local db=H.connect(f.root..'/library.db');db:close()
        local store=require('weread.lib.native_position_store'):new(f.host.library_db,f.client)
        store.read=function() return {phase='acknowledged',metadata={book_id='42'}} end
        -- Inject only the journal constructor; restore immediately after acquire.
        local Module=require('weread.lib.native_position_store');local new=Module.new
        Module.new=function() return store end;local release,why=Lease.acquire(f.host,'42',f.guard);Module.new=new
        expect(not release and why=='position_pending' and not f.stops);f.host.read_report.job={}
    end
    expect(not f.start());expect(f.posts==0 and not f.stops and not f.host._offline_time_transfer_lock,busy)
end
-- Closing a valid view resumes timers; account/view changes never revive them.
f=fixture();expect(f.start());expect(f.service:cancel());expect(f.restarts==1 and f.refreshes==1 and f.posts==0)
for _i,change in ipairs({'view','auth','deadline'}) do
    f=fixture();expect(f.start())
    if change=='view' then f.valid=false elseif change=='auth' then f.state.valid=false else f.clock=f.clock+71 end
    f.service.job.poll();expect(f.result.kind=='cancelled' and not f.service.job and not f.gate.active)
    expect(not f.restarts and not f.refreshes and not f.host._offline_time_transfer_lock and f.posts==0,change)
end
-- A complete imported TXT needs two source passes over every chapter. Give
-- its worker a bounded chapter-aware deadline while keeping cancellation live.
f=fixture()
local multi_input={book_id='CB_Synthetic',book_version=0}
local multi_refs={{file='/synthetic.epub',chapter_uid='7',chapter_idx=0,chapters={{chapterUid='7',chapterIdx=0},{chapterUid='8',chapterIdx=1}}}}
expect(f.service:start('send',f.account,multi_input,multi_refs,f.guard,function(value) f.result=value end))
expect(f.service.job.deadline==130)
expect(f.worker.timeout==130,'worker retained its shorter default timeout')
f.clock=f.clock+71;expect(f.service:_current(f.service.job),'multi-chapter worker timed out at single-chapter deadline')
f.clock=f.clock+60;f.service.job.poll()
expect(f.result.kind=='cancelled' and not f.service.job and not f.gate.active and f.posts==0,'multi-chapter deadline did not cancel')
f=fixture();local many={}
for i=1,10000 do many[i]={chapterUid=tostring(i),chapterIdx=i} end
multi_refs[1].chapters=many
expect(f.service:start('send',f.account,multi_input,multi_refs,f.guard,function(value) f.result=value end))
expect(f.service.job.deadline==3600 and f.worker.timeout==3600 and f.service:cancel(),'large scope deadline must be bounded')
f.gate.active=true;expect(f.start() and f.worker.timeout==70,'reused worker retained an old long timeout')
expect(f.service:cancel(),'reused worker could not be cancelled')
-- Exercise the actual MemoryWorker timeout, not only the parent's deadline.
-- The runner is deterministic; no real process or network is started.
local function attach_memory_worker(context,discard)
    local run,bytes,done,terminated=nil,'',false,false
    local runner={
        run=function(fn) run=fn;return 21,22 end,
        write=function(_fd,value) if not discard then bytes=bytes..value;done=true end;return true end,
        read=function() local result=bytes;bytes='';return result end,
        done=function() return done end,
        close=function() end,
        terminate=function() terminated=true;done=true end,
    }
    context.worker=require('weread.lib.memory_worker'):new{scheduler=context.scheduler,codec=context.client,
        runner=runner,now=function() return context.clock end}
    context.service.worker=context.worker
    return {run=function() context.in_child=true;run(22);context.in_child=false end,
        terminated=function() return terminated end}
end
f=fixture();local memory=attach_memory_worker(f,false)
multi_refs[1].chapters={{chapterUid='7',chapterIdx=0},{chapterUid='8',chapterIdx=1}}
expect(f.service:start('send',f.account,multi_input,multi_refs,f.guard,function(value) f.result=value end))
local memory_job=f.worker.job;f.clock=f.clock+76;memory_job.poll()
expect(f.worker.job==memory_job and not memory.terminated() and not f.result,
    'actual worker abandoned the job at its old 75-second timeout')
memory.run();memory_job.poll();memory_job.poll()
expect(f.result.kind=='unavailable' and not f.service.job and not memory.terminated() and f.posts==0,
    'long-running worker could not deliver its result')
-- A timeout after a possibly dispatched request keeps the durable claim; a
-- later attempt cannot send the same interval again.
f=fixture('lost');memory=attach_memory_worker(f,true);expect(f.start());memory.run()
expect(f.posts==1 and f.journal:pending(f.account).phase=='claimed','dispatch was not durably claimed')
f.clock=f.clock+71;f.service.job.poll()
expect(memory.terminated() and f.result.kind=='cancelled' and f.journal:pending(f.account).phase=='claimed',
    'timeout lost a possibly sent request')
f.gate.active=true;expect(not f.start() and f.posts==1,'timeout allowed a duplicate transfer')
-- If the worker died after a dispatch, cancellation keeps the sealed intent.
f=fixture('lost');expect(f.start());f.deliver()
expect(f.result.kind=='unconfirmed' and f.journal:pending(f.account).phase=='claimed' and f.posts==1)
local record=f.journal:pending(f.account);f.gate.active=true
expect(not f.start('send'));expect(f.posts==1)
expect(f.start('retire',record));f.deliver()
expect(f.result.kind=='completed' and f.ledger:summary(f.account).unknown==2 and not f.journal:pending(f.account))
expect(assert(f.journal:get(f.account,record.attempt)).phase=='retired')
-- ACK recovery survives a fresh service instance; neither tokens nor POSTs repeat.
f=fixture('no_delta');expect(f.start());f.deliver();record=f.journal:pending(f.account)
expect(f.result.kind=='unconfirmed' and record.phase=='acknowledged');f.mode=nil;f.applied=true;f.gate.active=true
local configs=f.configs;expect(f.start('resolve',record));f.deliver()
expect(f.result.kind=='confirmed' and f.posts==1 and f.configs==configs and f.ledger:summary(f.account).confirmed==2)
-- A corrupt child result cannot falsely mark the UI successful.
f=fixture();expect(f.start());f.worker.callback({kind='confirmed',attempt='offtime-v1:'..string.rep('a',32)})
expect(f.result.kind=='unconfirmed' and f.posts==0 and not f.host._offline_time_transfer_lock)
-- Failure to create the subprocess leaves timers and pending rows intact.
f=fixture();f.reject=true;expect(not f.start());expect(not f.service.job and f.restarts==1 and f.posts==0)
Signing.time_zone=zone
for _i,root in ipairs(roots) do os.execute('rm -rf '..string.format('%q',root)) end
print('readtime_transfer_service_spec: '..n..' checks')
