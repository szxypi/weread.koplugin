package.path='./?.lua;'..package.path
local Sync=require('weread.lib.membership_queue_sync')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local s={allowed=true,entry={book_id='41',id='one',before=false,desired=true,phase='queued'},notices={}}
    local q={}
    function q:list() return s.entry and {s.entry} or {} end
    function q:transition(e,phase)
        if e~=s.entry or e.phase~='queued' then return end
        local n={};for k,v in pairs(e) do n[k]=v end;n.phase=phase;s.entry=n;return n
    end
    function q:release_unsent(e)
        if e~=s.entry or e.phase~='dispatching' then return end
        local n={};for k,v in pairs(e) do n[k]=v end;n.phase='queued';s.entry=n;return n
    end
    function q:remove(e) if e~=s.entry then return false end;s.entry=nil;return true end
    local service={}
    function service:pending() return s.pending,s.error end
    function service:cancel() s.cancelled=true end
    function service:prepare(id,guard,callback) s.id,s.guard,s.preview=id,guard,callback;return not s.prepare_fail,s.prepare_fail end
    function service:preview_current(plan) return plan==s.plan end
    function service:commit(_,cb) s.commit=cb;s.count=(s.count or 0)+1;return not s.commit_fail end
    local sync=Sync:new{queue=q,service=service,allowed=function() return s.allowed end,
        cache=function(snapshot) s.cached=snapshot;return not s.cache_fail end,
        notify=function(phase) s.notices[#s.notices+1]=phase end}
    function s.prepared(before)
        s.plan={book_id='41',before=before,operation=before and 'remove' or 'add',snapshot={}}
        s.preview(s.plan)
    end
    return sync,s
end
local sync,s=fixture();expect(sync:pump() and s.id=='41','prepare not started');s.prepared(false)
expect(s.entry.phase=='dispatching' and s.count==1,'claim must precede single dispatch')
s.commit({kind='confirmed',attempted=true,snapshot={}},true)
expect(not s.entry and s.cached and s.notices[1]=='confirmed','verified change not saved')
sync,s=fixture();sync:pump();s.prepared(true)
expect(not s.entry and not s.count and s.cached,'already satisfied target was sent')
sync,s=fixture();s.cache_fail=true;sync:pump();s.prepared(true)
expect(s.entry.phase=='queued' and not s.count,'failed snapshot lost queued intent')
sync,s=fixture();s.cache_fail=true;sync:pump();s.prepared(false);s.commit({kind='confirmed',attempted=true,snapshot={}},true)
expect(s.entry.phase=='dispatching' and not sync:pump(),'failed snapshot allowed replay')
sync,s=fixture();sync:pump();s.prepared(false);s.commit({kind='changed',attempted=false},true)
expect(s.entry.phase=='queued' and s.notices[1]=='deferred','proven unsent change not retained')
sync,s=fixture();sync:pump();s.prepared(false);s.commit({kind='unconfirmed',attempted=true},false)
expect(s.entry.phase=='dispatching' and not sync:pump(),'uncertain operation replayed')
sync,s=fixture();sync:pump();s.prepared(false);sync:cancel();s.commit({kind='confirmed',attempted=true},true)
expect(s.entry.phase=='dispatching' and #s.notices==0,'late response changed cancelled job')
sync,s=fixture();sync:pump();s.allowed=false;s.prepared(false)
expect(s.entry.phase=='queued' and not s.count,'stale account/network dispatched')
sync,s=fixture();s.pending=true;expect(not sync:pump() and not s.preview,'pending journal ignored')
sync,s=fixture();s.error='storage';expect(not sync:pump(),'invalid journal ignored')
sync,s=fixture();s.entry.phase='dispatching';expect(not sync:pump(),'interrupted request replayed')
sync,s=fixture();s.commit_fail=true;sync:pump();s.prepared(false)
expect(s.entry.phase=='dispatching' and s.notices[1]=='unconfirmed','failed startup released uncertain claim')
sync,s=fixture();sync:pump();s.preview(nil,'native_expired')
expect(s.entry.phase=='queued' and s.notices[1]=='login','expired login lost intent')
print('membership_queue_sync_spec: '..checks..' checks')
