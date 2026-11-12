package.path='./?.lua;'..package.path
local Service=require('weread.lib.native_position_service');local Task=require('weread.lib.native_position_task')
local C=require('weread.lib.native_position_contract');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local f={clock=100,source=true,guard_calls=0,starts=0,stops=0,events={},gates={},source_in_child=0}
    local settings,credentials,auth=F.access();f.settings,f.auth=settings,auth
    local grant={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
    function credentials:read() return grant,auth.revision,nil,auth.pending end
    local before={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic original full summary'}
    local desired=F.clone(before);desired.chapter_offset=13;desired.summary='synthetic desired full summary'
    f.metadata={book_id='41',before=before,desired=desired,counts={readingTime=10,recordReadingTime=20,ttsTime=0},version=0,
        shelf_sha256=string.rep('a',64),source_sha256=string.rep('b',64),file_id='synthetic-file',basis='raw_txt_utf16'}
    f.row={schema=1,phase='idle',revision=0,account=C.account_key('900000')}
    local function same(record) return f.row.id==record.id and f.row.account==record.account and C.same(f.row.metadata,record.metadata) end
    f.journal={read=function() return F.clone(f.row) end,owns=function(_self,record,phase) return same(record) and (not phase or f.row.phase==phase) end,
        begin=function(_self,metadata,scope,revision)
            if f.row.phase~='idle' or revision~=f.row.revision then return nil end
            f.row={schema=1,phase='prepared',id=string.rep('1',32),epoch=scope.epoch,revision=revision+1,account=C.account_key(scope.vid),metadata=F.clone(metadata)}
            return F.clone(f.row)
        end,
        advance=function(_self,record,phase,next_phase)
            if not same(record) or f.row.revision~=record.revision or f.row.phase~=phase then return nil end
            f.row.phase,f.row.revision=next_phase,f.row.revision+1;return F.clone(f.row)
        end,
        finish=function(_self,record,phase)
            if not same(record) or f.row.revision~=record.revision or f.row.phase~=phase or phase~='prepared' and phase~='verified' then return false end
            f.row={schema=1,phase='idle',revision=f.row.revision+1,account=f.row.account};return true
        end}
    f.worker={start=function(_self,task,callback)
        f.starts=f.starts+1;f.task,f.deliver=task,callback;return not f.fail_start
    end,cancel=function() f.stops=f.stops+1 end}
    f.scheduler={scheduleIn=function(_self,delay,callback) expect(delay>=.1);f.events[callback]=delay end,unschedule=function(_self,callback) f.events[callback]=nil end}
    f.guard=function()
        if f.inside_task then f.source_in_child=f.source_in_child+1;error('native document used in worker') end
        f.guard_calls=f.guard_calls+1;return f.source
    end
    local function guard_factory()
        if f.no_gate then return nil end
        local gate={open=true,valid=function(self) return self.open end,close=function(self) self.open=false end}
        f.gates[#f.gates+1]=gate;return gate
    end
    f.service=Service:new{settings=settings,credentials=credentials,client=F.codec(),scheduler=f.scheduler,journal=f.journal,worker=f.worker,
        now=function() return f.clock end,guard_factory=guard_factory}
    f.callback=function(value,token) f.result,f.token=value,token end
    function f.start() return f.service:start(f.metadata,f.guard,f.callback) end
    function f.run()
        local old=Task.run
        Task.run=function(_client,_settings,_access,record,store,options)
            expect(options.is_current(),'worker guard absent');expect(f.source_in_child==0)
            expect(record.metadata.desired.chapter_offset==13,'mutable input changed captured plan')
            if f.noop then return {kind='noop',attempted=false,acknowledged=false,readbacks=0} end
            record=assert(store:advance(record,'prepared','pending'))
            if not f.stop_pending then record=assert(store:advance(record,'pending','acknowledged')) end
            if not f.stop_ack and not f.stop_pending then assert(store:advance(record,'acknowledged','verified')) end
            return {kind=f.forge_confirmed or not f.stop_ack and not f.stop_pending and 'confirmed' or 'unconfirmed',attempted=true,acknowledged=not f.stop_pending,readbacks=1}
        end
        f.inside_task=true;local ok,value=pcall(f.task);f.inside_task=false;Task.run=old;expect(ok);f.deliver(value)
    end
    return f
end
local f=fixture();expect(f.start());f.metadata.desired.chapter_offset=99;f.run()
expect(f.result.kind=='confirmed' and f.row.phase=='verified' and f.token and f.source_in_child==0)
expect(not f.service:accept({}));f.source=false;expect(f.service:accept(f.token),'completed receipt incorrectly depended on current page')
expect(f.row.phase=='idle' and next(f.events)==nil and not f.gates[1]:valid())
f=fixture();expect(f.start());f.source=false;f.service:on_view_changed()
expect(f.row.phase=='idle' and f.stops==1 and not f.gates[1]:valid() and not f.service.job)
f.deliver({kind='confirmed',attempted=true,acknowledged=true,readbacks=1});expect(f.result==nil,'late cancelled callback applied')
f=fixture();expect(f.start());f.row.phase='pending';f.row.revision=f.row.revision+1;f.source=false;f.service:on_view_changed()
expect(f.row.phase=='pending' and f.stops==1,'claimed cancellation released write')
f=fixture();f.no_gate=true;expect(not f.start());expect(f.row.phase=='idle' and f.starts==0)
f=fixture();f.fail_start=true;expect(not f.start());expect(f.row.phase=='idle' and f.stops==1 and next(f.events)==nil)
f=fixture();expect(f.start());f.clock=171;f.service:on_view_changed();expect(f.row.phase=='idle' and f.stops==1)
f=fixture();f.stop_pending=true;f.forge_confirmed='confirmed';expect(f.start());f.run()
expect(f.result.kind=='unconfirmed' and not f.token and f.row.phase=='pending','forged result bypassed durable proof')
expect(not f.service:resolve(f.guard,f.callback));expect(f.starts==1,'unknown write replayed')
f=fixture();f.stop_ack=true;expect(f.start());f.run();expect(f.row.phase=='acknowledged' and not f.token)
f.settings:get_auth_scope().epoch=2
expect(f.service:resolve(f.guard,f.callback));local old=Task.resolve
Task.resolve=function(_client,_settings,_access,record,store,options)
    expect(options.is_current());assert(store:advance(record,'acknowledged','verified'))
    return {kind='confirmed',attempted=false,acknowledged=true,readbacks=2}
end
f.inside_task=true;local result=f.task();f.inside_task=false;Task.resolve=old;f.deliver(result)
expect(f.result.kind=='confirmed' and f.row.phase=='verified' and f.service:accept(f.token))
f=fixture();expect(f.start());f.run();local pending=F.clone(f.row);f.service:cancel()
f.source=false;local starts=f.starts;expect(f.service:resolve(function() error('current source not relevant to old completed receipt') end,f.callback))
expect(f.result.kind=='completed' and f.result.attempted==false and f.starts==starts and f.service:accept(f.token))
expect(f.row.phase=='idle' and pending.phase=='verified')
f=fixture();expect(f.start());f.row.phase='acknowledged';f.row.revision=f.row.revision+2;f.auth.revision=2;f.deliver({kind='confirmed',attempted=true,acknowledged=true,readbacks=1})
expect(f.result==nil and f.row.phase=='acknowledged' and f.stops==1,'new grant accepted old callback')
f=fixture();f.metadata.before=F.clone(f.metadata.desired);f.noop=true;expect(f.start());f.run()
expect(f.result.kind=='noop' and f.row.phase=='idle' and not f.token)
f=fixture();expect(f.start());f.row.metadata.desired.chapter_offset=55;f.deliver({kind='confirmed',attempted=true,acknowledged=true,readbacks=1})
expect(f.result.kind=='unconfirmed' and f.row.phase=='prepared' and not f.token,'changed plan accepted')
print('PASS native_position_service_spec '..checks)
