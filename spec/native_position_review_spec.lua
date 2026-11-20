package.path='./?.lua;'..package.path
local Review=require('weread.lib.native_position_review')
local Task=require('weread.lib.native_position_review_task')
local F=require('spec.helpers.thought_edit_fixture')
local Fixture=require('spec.helpers.native_position_review_fixture')
local checks=0;local function expect(value,why) checks=checks+1;assert(value,why) end
local function fixture()
    local f=Fixture.new()
    f.options.task=function(_client,_settings,_access,record,_journal,gate)
        expect(gate:valid() and record.phase==f.row.phase,'child did not get primitive gate')
        return {kind='observed',readbacks=2,observation=F.clone(f.observation)}
    end
    f.review=Review:new(f.options)
    function f:start() return self.review:start(self.guard,self.callback) end
    function f:run() self.inside=true;local value=self.task();self.inside=false;self.deliver(value) end
    return f
end
for _i,phase in ipairs({'prepared','pending','acknowledged','verified'}) do
    local f=fixture();f.row.phase=phase;expect(f:start());f:run()
    expect(f.result.kind=='observed' and f.result.phase==phase and f.result.percent==17 and f.result.observation==nil)
    expect(f.row.phase==phase and f.archives==0 and f.review:current(f.token),'read-only inspection mutated old result')
    expect(not f.review:archive({}) and f.archives==0,'forged receipt archived old result')
    expect(f.review:archive(f.token) and f.history.phase==phase and f.row.phase=='idle','old phase was relabelled')
    expect(not f.review:archive(f.token) and f.archives==1 and next(f.events)==nil)
end
for _i,change in ipairs({'page','clock','rollback','account','grant','revision','phase','point'}) do
    local f=fixture();expect(f:start());f:run()
    if change=='page' then f.current=false
    elseif change=='clock' then f.clock=141
    elseif change=='rollback' then f.clock=99
    elseif change=='account' then f.auth.valid=false
    elseif change=='grant' then f.auth.revision=2
    elseif change=='revision' then f.row.revision=f.row.revision+1
    elseif change=='phase' then f.row.phase='acknowledged'
    else f.review.context.observation.point.summary='mutated' end
    expect(not f.review:archive(f.token) and f.archives==0,'stale '..change..' archived pending row');f.review:cancel()
end
local f=fixture();expect(f:start());f.current=false;next(f.events)()
expect(f.result.kind=='cancelled' and f.stops==1 and f.row.phase=='pending' and f.gate_closed)
f.deliver({kind='observed',readbacks=2,observation=f.observation});expect(f.token==nil,'late child restored cancelled UI')
for _i,mutate in ipairs({function(r) r.readbacks=1 end,function(r) r.observation.point.book_id='42' end,
    function(r) r.observation.counts.readingTime=true end,function(r) r.kind='confirmed' end}) do
    f=fixture();expect(f:start());local r={kind='observed',readbacks=2,observation=F.clone(f.observation)};mutate(r);f.deliver(r)
    expect(f.result.kind=='unavailable' and not f.token and f.row.phase=='pending')
end
f=fixture();expect(f:start());f:run();f.fail_archive=true
expect(not f.review:archive(f.token) and f.row.phase=='pending' and f.review.context==nil,'failed storage cleared record')
f=fixture();f.fail_start=true;expect(not f:start() and f.row.phase=='pending' and next(f.events)==nil)
f=fixture();f.auth.pending=true;expect(not f:start() and f.starts==0)
f=fixture();f.row.phase='idle';expect(not f:start() and f.starts==0)
f=fixture();f.row.account=string.rep('c',20);expect(not f:start() and f.starts==0)
f=fixture();local original=F.clone(f.row);f.row.revision=3;expect(not Task.current(f.journal,original),'revision mismatch accepted')
f=fixture();local expected=F.clone(f.row);f.row.revision=3
local started,why=f.review:start(f.guard,f.callback,expected);expect(not started and why=='changed' and f.starts==0,'initial record replaced before inspection')
print('native_position_review_spec: '..checks..' checks')
