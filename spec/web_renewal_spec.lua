package.path='./?.lua;'..package.path
local state
local function clone(value) return {scope={vid=value.scope.vid,epoch=value.scope.epoch},revision=value.revision} end
local Auth={}
function Auth.capture() assert(state.memory.revision==state.disk.revision,'changed');return clone(state.memory) end
function Auth.memory() return clone(state.memory) end
function Auth.primary() return clone(state.disk) end
function Auth.current(_settings,input) return state.memory.revision==input.revision and state.disk.revision==input.revision end
function Auth.snapshot(value,scope)
    assert(type(value)=='table' and value.scope.vid==scope.vid and value.scope.epoch==scope.epoch,'wrong receipt')
    return clone(value)
end
function Auth.run(_client,input,candidate)
    if not candidate then state.posts=state.posts+1 end
    if state.unknown then return {ok=false,attempted=true} end
    if state.preflight_error then return {ok=false,attempted=false} end
    return {ok=not state.verify_failed,attempted=candidate==nil,candidate=candidate or {scope=input.scope,revision='renewed'},book_count=2}
end
package.preload['weread.lib.web_authorization']=function() return Auth end
package.preload['weread.lib.web_renewal_store']=function() return {} end
package.preload['weread.lib.memory_worker']=function() return {} end
local Service=require('weread.lib.web_renewal')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local owner={vid='123',epoch=1}
    state={memory={scope=owner,revision='original'},disk={scope=owner,revision='original'},record={revision=0,phase='idle'},posts=0,tasks={},released=0,callbacks={}}
    local store={sync=function() return not state.sync_failed end,path='intent'}
    function store:read() return state.record end
    function store:begin(input)
        if state.record.scope and state.record.scope.epoch==input.scope.epoch then
            if state.record.phase=='pending' then return nil,'renewal_unconfirmed' end
            if state.record.phase=='candidate' or state.record.phase=='verified' then return state.record,'resume' end
        end
        state.record={revision=state.record.revision+1,phase='pending',scope=input.scope,input_revision=input.revision};return state.record
    end
    function store:receipt(input,record,candidate,verified)
        if state.fail_receipt=='before' then return nil,'save_failed' end
        state.record={revision=record.revision+1,phase=verified and 'verified' or 'candidate',scope=input.scope,input_revision=input.revision,target_revision=candidate.revision,candidate=candidate}
        if state.fail_receipt=='visible' then return nil,'save_failed' end
        return state.record
    end
    function store:apply(_input,record)
        if state.fail_apply then return false,'save_failed' end
        state.memory=clone(record.candidate);state.disk=clone(record.candidate)
        state.record={revision=record.revision+1,scope=record.scope,input_revision=record.candidate.revision,phase='done'}
        if state.fail_done then return false,'save_failed' end
        return true,clone(state.memory)
    end
    function store:release(input,record)
        state.released=state.released+1;state.record={revision=record.revision+1,scope=input.scope,input_revision=input.revision,phase='done'};return state.record
    end
    function store:align() return false end
    local settings={settings_file='settings',auth_scope_matches=function(_self,scope)
        return scope and scope.vid==state.memory.scope.vid and scope.epoch==state.memory.scope.epoch
    end}
    local worker={start=function(self,task,callback)
        if state.start_failed then return false end
        if state.start_throws then self.job={};error('private dispatch error') end
        self.job={};state.tasks[#state.tasks+1]={task=task,callback=callback};return true
    end,cancel=function(self) self.job=nil;state.cancelled=true end}
    local function make() return Service:new{settings=settings,client={},scheduler={},store=store,worker=worker} end
    local function callback(ok,reason) state.callbacks[#state.callbacks+1]={ok=ok,reason=reason} end
    local function deliver(index,result)
        local item=state.tasks[index or #state.tasks];worker.job=nil;item.callback(result or item.task())
    end
    return {service=make(),make=make,callback=callback,deliver=deliver}
end
local f=fixture();expect(f.service:start({},f.callback),'start failed')
expect(state.record.phase=='pending' and state.posts==0,'POST preceded durable intent');f.deliver()
expect(state.posts==1 and state.record.phase=='done' and #state.callbacks==1 and state.callbacks[1].ok and not f.service.job,'confirmed flow did not save/finish once')
for _,problem in ipairs({'fail_receipt_before','fail_receipt_visible','fail_apply','fail_done'}) do
    f=fixture()
    if problem=='fail_receipt_before' then state.fail_receipt='before' elseif problem=='fail_receipt_visible' then state.fail_receipt='visible' else state[problem]=true end
    f.service:start({},f.callback);f.deliver()
    expect(f.service.job and f.service.job.state=='save_failed' and state.posts==1 and not state.callbacks[1].ok,'save failure lost receipt: '..problem)
    state.fail_receipt=nil;state.fail_apply=false;state.fail_done=false
    expect(f.service:start({},f.callback),'save-only retry refused')
    expect(not f.service.job and state.posts==1 and #state.tasks==1 and state.callbacks[2].ok,'save-only retry repeated network: '..problem)
end
f=fixture();f.service:start({},f.callback);f.service:cancel();f.deliver()
expect(state.record.phase=='pending' and #state.callbacks==0 and state.released==0,'cancel released possibly dispatched POST or called old f.callback')
local reopened=f.make();local started,reason=reopened:start({},f.callback)
expect(not started and reason=='renewal_unconfirmed' and #state.tasks==1,'reopened f.service replayed unknown POST')
f=fixture();state.unknown=true;f.service:start({},f.callback);f.deliver()
expect(state.record.phase=='pending' and state.posts==1 and state.callbacks[1].reason=='renewal_unconfirmed','lost receipt was cleared/retried')
f=fixture();state.verify_failed=true;f.service:start({},f.callback);f.deliver()
expect(state.record.phase=='candidate' and state.posts==1 and not f.service.job and state.callbacks[1].reason=='verification_unconfirmed','received unverified receipt not durable')
state.verify_failed=false;reopened=f.make();reopened:start({},f.callback);f.deliver()
expect(state.posts==1 and #state.tasks==2 and state.callbacks[2].ok and state.record.phase=='done','verification-only recovery repeated renewal')
f=fixture();state.start_failed=true;f.service:start({},f.callback)
expect(state.released==1 and state.posts==0 and state.record.phase=='done','proved start failure retained intent')
f=fixture();state.start_throws=true;f.service:start({},f.callback)
expect(state.released==0 and state.record.phase=='pending' and state.callbacks[1].reason=='renewal_unconfirmed','unknown dispatch exception released intent')
f=fixture();f.service:start({},f.callback);state.memory.revision='other';state.disk.revision='other';f.deliver()
expect(state.callbacks[1].reason=='session_changed' and state.record.phase=='pending','changed Cookie authority accepted old receipt')
f=fixture();local current=true;f.service:start({is_current=function() return current end},f.callback);current=false;f.deliver()
expect(state.callbacks[1].reason=='session_changed' and state.record.phase=='pending','changed operation owner saved old receipt')
f=fixture();started,reason=f.service:start({is_current=function() return false end},f.callback)
expect(not started and reason=='session_changed' and state.record.revision==0,'stale operation reserved intent')
print('PASS: Web renewal orchestration, durable no-replay and save-only retry ('..checks..' checks)')
