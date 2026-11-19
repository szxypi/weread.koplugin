package.path='./?.lua;'..package.path
local Sync=require('weread.lib.finish_queue_sync')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local state={allowed=true,entry={book_id='41',id='one',before=false,desired=true,phase='queued'},notifications={}}
    local queue={}
    function queue:list() return state.entry and {state.entry} or {} end
    function queue:transition(entry,phase)
        if state.entry~=entry or entry.phase~='queued' then return nil end
        local next_entry={};for key,value in pairs(entry) do next_entry[key]=value end
        next_entry.phase=phase;state.entry=next_entry;return next_entry
    end
    function queue:release_unsent(entry)
        if state.entry~=entry or entry.phase~='dispatching' then return nil end
        local next_entry={};for key,value in pairs(entry) do next_entry[key]=value end
        next_entry.phase='queued';state.entry=next_entry;return next_entry
    end
    function queue:remove(entry) if state.entry~=entry then return false end;state.entry=nil;return true end
    local service={}
    function service:pending() return state.pending,state.pending_error end
    function service:cancel() state.cancelled=(state.cancelled or 0)+1 end
    function service:prepare(id,guard,callback,resolving,desired)
        state.guard,state.preview=guard,callback;state.request={id=id,resolving=resolving,desired=desired};return not state.prepare_failure
    end
    function service:preview_current(plan) return state.plan==plan end
    function service:commit(_plan,callback) state.commit=callback;state.commit_count=(state.commit_count or 0)+1;return not state.commit_failure end
    local sync=Sync:new{queue=queue,service=service,allowed=function() return state.allowed end,
        notify=function(kind) state.notifications[#state.notifications+1]=kind end}
    function state.prepared(before,desired)
        state.plan={metadata={book_id='41',before=before,desired=desired}}
        state.preview(state.plan)
    end
    return sync,state
end
local sync,s=fixture();expect(sync:pump() and s.request.desired==true and s.request.resolving==false,'queued target not passed to online preview')
expect(not sync:pump(),'concurrent pump started');s.prepared(false,true)
expect(s.entry.phase=='dispatching' and s.commit_count==1,'dispatch did not persist claim first')
s.commit({kind='confirmed',attempted=true},true)
expect(not s.entry and s.notifications[1]=='confirmed','verified change did not clear exact claim')
sync,s=fixture();sync:pump();s.prepared(true,true);s.commit({kind='noop',attempted=false},true)
expect(not s.entry and s.notifications[1]=='confirmed','already applied cloud target was resent or left queued')
sync,s=fixture();sync:pump();s.prepared(false,true);s.commit({kind='changed',attempted=false},true)
expect(s.entry.phase=='queued' and s.notifications[1]=='deferred','proven unsent operation did not remain queued')
sync,s=fixture();sync:pump();s.prepared(false,true);s.commit({kind='unconfirmed',attempted=true},false)
expect(s.entry.phase=='dispatching' and s.notifications[1]=='unconfirmed' and not sync:pump(),'uncertain request was automatically replayed')
sync,s=fixture();sync:pump();s.prepared(false,true);sync:cancel();s.commit({kind='confirmed',attempted=true},true)
expect(s.entry.phase=='dispatching' and #s.notifications==0,'late response cleared interrupted claim')
sync,s=fixture();sync:pump();s.allowed=false;s.prepared(false,true)
expect(s.entry.phase=='queued' and not s.commit_count,'account or network change dispatched stale plan')
sync,s=fixture();s.pending=true;expect(not sync:pump() and not s.preview,'existing online write was ignored')
sync,s=fixture();s.pending_error='storage';expect(not sync:pump() and not s.preview,'journal failure did not stop queue')
sync,s=fixture();s.entry.phase='dispatching';expect(not sync:pump(),'interrupted write was replayed on startup')
sync,s=fixture();s.commit_failure=true;sync:pump();s.prepared(false,true)
expect(s.entry.phase=='dispatching' and s.notifications[1]=='unconfirmed','failed startup was incorrectly retried')
print('finish_queue_sync_spec: '..checks..' checks')
