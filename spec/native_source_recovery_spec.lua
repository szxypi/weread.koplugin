package.path='./?.lua;'..package.path
local Recovery=require('weread.lib.native_source_recovery')
local Access=require('weread.lib.native_read_access');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why) end
local function fixture()
    local f={current=true,posts=0,cancels=0};local settings,store,state=F.access();f.settings,f.store,f.state=settings,store,state
    f.grant={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-old-access',refreshToken='synthetic-refresh'}
    function store:read() return F.clone(f.grant),state.revision,nil,state.pending end
    local service={start=function(self,options,callback)
        expect(options.expected_revision==1 and not state.pending);f.posts=f.posts+1
        state.revision,state.pending=2,true;self.job={};f.callback=callback;return true,self.job
    end,cancel=function(self,handle) expect(handle==self.job);f.cancels=f.cancels+1;self.job=nil end}
    f.service=service;f.selected=Access.capture(settings,store)
    f.recovery=Recovery:new{settings=settings,client={},scheduler={},renewal=service}
    function f:start()
        return self.recovery:start(self.selected,function() expect(not self.in_child,'native guard ran in child');return self.current end,
            function(fresh,reason) self.fresh=fresh;self.reason=reason;self.delivered=true end)
    end
    function f:finish()
        self.grant.accessToken='synthetic-new-access';state.revision,state.pending=3,false
        self.callback(true)
    end
    return f
end
local f=fixture();expect(f:start());f:finish();expect(f.fresh and f.fresh.revision==3 and f.posts==1)
expect(not f.recovery.job and f.cancels==1)
expect(f.reason==nil,'successful recovery carried an authentication error')
for _i,change in ipairs({'page','account','revision','pending','device'}) do
    f=fixture();expect(f:start())
    f.grant.accessToken='synthetic-new-access';f.state.revision,f.state.pending=3,false
    if change=='page' then f.current=false elseif change=='account' then f.state.valid=false
    elseif change=='revision' then f.state.revision=5 elseif change=='pending' then f.state.pending=true
    else f.grant.deviceId='eink334691225'..string.rep('2',19) end
    f.callback(true);expect(f.delivered and not f.fresh and f.posts==1,'adopted stale '..change)
end
f=fixture();local started,handle=f:start();expect(started);f.recovery:cancel(handle);f:finish()
expect(not f.delivered and f.state.revision==3 and f.posts==1,'cancelled result was adopted')
f=fixture();f:start();f.service.job.state='save_failed';f.callback(false)
expect(f.delivered and not f.fresh and f.service.job and f.service.job.state=='save_failed' and f.cancels==0,'verified save-only retry was lost')
f=fixture();f.current=false;expect(not f:start() and f.posts==0)
f=fixture();f.state.pending=true;expect(not f:start() and f.posts==0)
print('native_source_recovery_spec: '..checks..' checks')
