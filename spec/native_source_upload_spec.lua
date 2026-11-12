package.path='./?.lua;'..package.path
local Upload=require('weread.lib.native_source_upload')
local F=require('spec.helpers.thought_edit_fixture')
local checks=0
local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local function fixture()
    local f={valid=true,online=true,receipt_valid=true,clock=100,starts=0,accepts=0,prepared=0,callbacks=0,timers={},events={}}
    local settings,store,auth=F.access();f.auth=auth
    local grant={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
    function store:read() return grant,auth.revision,nil,auth.pending end
    f.point={book_id='41',chapter_uid='2',chapter_offset=13,file_id=string.rep('a',64),book_version=7,
        raw_sha256=string.rep('b',64),render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=false}
    f.candidate={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=13,raw_percent=18,
        summary='Exact raw summary\r\n　 remains',basis='raw_txt_utf16',upload_verified=false}
    f.before={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='Complete original summary'}
    f.remote=F.clone(f.before);f.remote.source='web';f.remote.has_chapter_offset=true;f.remote.has_chapter_index=true
    f.metadata={book_id='41',before=F.clone(f.before),desired=require('weread.lib.native_position_protocol').point(f.candidate),
        counts={readingTime=10,recordReadingTime=20,ttsTime=0},version=0,shelf_sha256=string.rep('c',64),
        source_sha256=f.point.raw_sha256,file_id=f.point.file_id,basis='raw_txt_utf16'}
    f.intent={book_id='41',percent=18,source_position=F.clone(f.point),expected_remote=F.clone(f.remote)}
    f.source={client={settings=settings},is_online=function() return f.online end,
        current=function() return F.clone(f.point) end,_live=function() return {book_id='41'} end,_current=function() return f.valid end,
        cancel_upload_preview=function() f.receipt_valid=false end,
        is_current_native_preview=function() return f.receipt_valid end,native_preview_deadline=function() return 130 end,
        prepare_current_native_preview=function(_self,cb) f.prepared=f.prepared+1;f.capture=cb;f.receipt_valid=true end}
    f.service={pending=function() return f.pending and {phase=f.pending} or nil end,
        cancel=function(self) self.job=nil end,
        start=function(self,metadata,guard,cb)
            f.starts=f.starts+1;f.sent=F.clone(metadata);f.guard=guard;f.deliver=cb
            self.job={};return not f.start_fail,'storage'
        end,
        accept=function() f.accepts=f.accepts+1;f.events[#f.events+1]='accept';f.pending=nil;return true end,
        resolve=function(_self,_guard,cb)
            if f.pending=='prepared' then f.pending=nil;cb({kind='aborted'});return true end
            cb({kind='completed'},{});return true
        end}
    f.worker={start=function(_self,task,cb) f.task,f.probe=task,cb;return not f.worker_fail end,cancel=function() end}
    local scheduler={scheduleIn=function(_self,delay,fn) expect(delay>=.1);f.timers[fn]=true end,
        unschedule=function(_self,fn) f.timers[fn]=nil end}
    f.upload=Upload:new{source=f.source,scheduler=scheduler,credentials=store,service=f.service,worker=f.worker,
        now=function() return f.clock end,make_gate=function()
            local gate={valid=function() return not f.gate_closed end,close=function() f.gate_closed=true end};return gate
        end,snapshot=function(_client,_settings,_access,input,gate)
            expect(gate:valid(),'snapshot lacked cancellation gate')
            expect(input.source.book_version==7 and input.candidate.raw_percent==18,'source inputs changed')
            return {kind=f.snapshot_kind or 'ready',metadata=F.clone(f.metadata)}
        end}
    f.callback=function(plan,reason) f.plan,f.reason=plan,reason;f.callbacks=f.callbacks+1 end
    function f:prepare()
        expect(self.upload:prepare(self.intent,self.callback));self.capture(F.clone(self.candidate),nil,{})
        if self.probe then self.probe(self.task()) end
    end
    return f
end
local f=fixture();f:prepare()
expect(f.plan and f.plan.transport=='native_position' and f.plan.basis=='raw_txt_utf16')
expect(f.plan.is_current() and f.plan.position.summary==f.candidate.summary and f.plan.position.percent==18)
expect(f.metadata.version==0 and f.plan.source_position.book_version==7,'archive version became API version')
expect(f.plan.dispatch(function(ok,accepted,result)
    expect(ok and accepted and result.position_confirmed and result.acknowledged)
    f.plan.release();f.events[#f.events+1]='local_saved'
end))
expect(f.starts==1 and f.sent.version==0 and f.guard(),'sender did not receive the bound metadata')
f.service.job=nil;f.pending='verified';f.deliver({kind='confirmed',attempted=true,acknowledged=true,readbacks=1},{})
expect(f.events[1]=='local_saved' and f.events[2]=='accept','journal retired before local commit')
expect(f.accepts==1 and not f.upload.job and next(f.timers)==nil)
expect(not f.plan.dispatch(function() error('replayed') end) and f.starts==1,'same plan dispatched twice')
for _i,key in ipairs({'position','source','deadline','expiry','account'}) do
    f=fixture();f:prepare()
    if key=='position' then f.plan.position.chapter_offset=99 elseif key=='source' then f.plan.source_position.raw_sha256='bad'
    elseif key=='deadline' then f.plan.deadline=999 elseif key=='expiry' then f.clock=131 else f.auth.valid=false end
    expect(not f.plan.is_current() and not f.plan.dispatch(function() error('stale dispatch') end),'stale plan sent')
    expect(f.starts==0)
end
f=fixture();f:prepare();f.plan.dispatch(function() error('synthetic local SQLite failure') end)
f.service.job=nil;f.pending='verified';f.deliver({kind='confirmed',attempted=true,acknowledged=true,readbacks=1},{})
expect(f.pending=='verified' and f.accepts==0,'failed local commit destroyed recoverable receipt')
f=fixture();f.pending='verified';f:prepare();expect(f.accepts==1 and f.plan,'past verified receipt blocked new reader')
f=fixture();f.pending='prepared';f:prepare();expect(not f.pending and f.plan,'unclaimed restart state was not aborted')
for _i,phase in ipairs({'pending','acknowledged'}) do
    f=fixture();f.pending=phase
    expect(not f.upload:prepare(f.intent,f.callback) and f.reason=='upload_readback_unconfirmed')
    expect(f.pending==phase and f.prepared==0 and f.starts==0,'unknown state was replayed')
end
f=fixture();f:prepare();local ended
f.plan.dispatch(function(_ok,accepted,result) ended=result;expect(not accepted) end)
f.pending='pending';f.upload:cancel()
expect(ended and ended.error_kind=='unconfirmed' and ended.report_attempted and f.pending=='pending','cancel lost uncertainty or parent completion')
f=fixture();f:prepare();f.plan.dispatch(function(_ok,_accepted,result) ended=result end);f.upload:cancel()
expect(ended.error_kind=='position' and ended.report_attempted==false,'known unclaimed cancellation claimed a write')
f=fixture();f.metadata.before=F.clone(f.metadata.desired);f.intent.expected_remote=F.clone(f.metadata.before)
f.intent.expected_remote.source='native';f.intent.expected_remote.has_chapter_index=true;f.intent.expected_remote.has_chapter_offset=true
f:prepare();local no_write
f.plan.dispatch(function(_ok,accepted,result) no_write=result;expect(accepted) end)
f.service.job=nil;f.deliver({kind='noop',attempted=false,acknowledged=false,readbacks=0})
expect(no_write.read_only_confirmation and not no_write.acknowledged and f.accepts==0,'read-only equality invented a POST receipt')
for _i,kind in ipairs({'login','changed','unavailable'}) do
    f=fixture();f.snapshot_kind=kind;f:prepare()
    expect(not f.plan and f.starts==0 and not f.upload.job,'failed read preflight reached sender')
end
f=fixture();f.upload:prepare(f.intent,f.callback);f.intent.expected_remote.chapter_offset=999
f.capture(F.clone(f.candidate),nil,{});f.probe(f.task())
expect(f.plan,'caller mutated immutable expected cloud point')
f=fixture();f:prepare();local newer_token={};f.source.preview_token=newer_token
local cancelled=false;f.source.cancel_upload_preview=function() cancelled=true end
f.plan.release();expect(not cancelled,'releasing old native plan cancelled a newer source preparation')
f=fixture();local owned={};f.source.preview_token=owned;f:prepare()
cancelled=false;f.source.cancel_upload_preview=function() cancelled=true end
f.plan.release();expect(cancelled,'owned source preparation was not cancelled')
print(('native_source_upload_spec: %d checks'):format(checks))
