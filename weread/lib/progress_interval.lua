-- One opt-in deadline per dirty, verified native reading session. A timer
-- never catches up missed periods, wakes Wi-Fi, or replays an uncertain send.
local Readback = require('weread.lib.progress_readback')
local M = {}; M.__index = M
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
function M.minutes(value)
    return type(value)=='number' and value%1==0 and value>=1 and value<=60 and value or 0
end
function M:new(options)
    return setmetatable({sync=assert(options.sync),scheduler=assert(options.scheduler),now=options.now or os.time,
        is_report_busy=options.is_report_busy or function() return false end,
        cancel_preparation=options.cancel_preparation},self)
end
function M:halt()
    local cycle=self.cycle
    self.sync:cancel_remote_fetch(cycle)
    self.cycle,self.task,self.started,self.due,self.minutes_value=nil,nil,nil,nil,nil
    if self.scheduled and self.scheduler.unschedule then self.scheduler:unschedule(self.scheduled) end
    self.scheduled=nil
    local job=self.sync.upload_job
    if cycle and job and job.interval_cycle==cycle then
        self.sync.upload_job,self.sync.uploading=nil,false
        if job.plan and job.plan.release then job.plan.release() end
        if job.preparing and self.cancel_preparation then self.cancel_preparation() end
    end
end
function M:current(cycle)
    local sync=self.sync
    return self.cycle==cycle and not sync.suspended_at and sync:_session_current(cycle.scope)
        and cycle.scope.book_id==sync.current_book_id
        and cycle.scope.navigation_generation==sync.navigation_generation
        and M.minutes(sync:_config().upload_interval_minutes)==cycle.minutes
end
function M:_eligible()
    local sync=self.sync
    if M.minutes(sync:_config().upload_interval_minutes)==0 or not sync.verified or not sync.dirty
        or not sync.current_book_id or sync.suspended_at or sync.file_resume or not sync.prepare_upload then return false end
    if sync.source_state=='paused' or sync.source_state=='idle' or sync.source_state=='unavailable' then return false end
    local own=self.cycle and sync.upload_job and sync.upload_job.interval_cycle==self.cycle
    if sync.source_dispatch and sync.source_dispatch:pending(sync.current_book_id) and not own then return false end
    local point=sync.get_source_position and sync.get_source_position()
    -- A page turn briefly invalidates the source point. Keep the original
    -- deadline during capture, rather than postponing it on every page.
    point=point or sync.source_local_anchor
    return type(point)=='table' and point.book_id==sync.current_book_id
        and point.basis=='filtered_xhtml_utf16' and point.upload_verified==false
end
function M:refresh()
    if not self:_eligible() then self:halt();return false end
    local minutes=M.minutes(self.sync:_config().upload_interval_minutes)
    if self.minutes_value and self.minutes_value~=minutes then self:halt() end
    if self.task or self.cycle then return true end
    local now=self.now()
    self.minutes_value,self.started,self.due=minutes,now,now+minutes*60
    local task
    task=function()
        if self.task~=task then return end
        if self.now()<self.started then self:halt();self:refresh();return end
        if self.now()<self.due then self.scheduler:scheduleIn(self.due-self.now(),task);return end
        self.task,self.scheduled=nil,nil
        if not self:_eligible() then self:halt();return end
        if self.sync.uploading or self.sync.pulling or self.is_report_busy() then self:refresh();return end
        if not self.sync.is_online() then
            self.sync:checkpoint_local('interval_offline');self.sync:_clear_verified('network_disconnected');return
        end
        self:_begin(minutes)
    end
    self.task,self.scheduled=task,task
    self.scheduler:scheduleIn(minutes*60,task)
    return true
end
function M:reschedule()
    self:halt();return self:refresh()
end
function M:finish(cycle)
    if self.cycle~=cycle then return end
    self.cycle=nil;self:refresh()
end
function M:_failed(cycle)
    if not self:current(cycle) then return end
    self.sync:checkpoint_local('interval_unavailable')
    self.sync:_clear_verified('interval_unavailable')
end
function M:_begin(minutes)
    local sync=self.sync
    local cycle={scope=sync:_scope(),minutes=minutes,baseline=copy(sync.remote_position)}
    self.cycle=cycle
    local started=sync.run_online('progress_interval',function()
        if not self:current(cycle) then return end
        local ok=pcall(function()
            local position,reason,context=sync:capture_local()
            if not position or reason or not context then self:_failed(cycle);return end
            sync:fetch_remote_checked(context.book_id,context.chapters,cycle,function() return self:current(cycle) end,function(remote,reason_)
                if not self:current(cycle) then return end
                if not remote then
                    if reason_=='progress_authentication_unavailable' then sync.notify('pull_failed',{error=reason_}) end
                    self:_failed(cycle);return
                end
                position=sync:capture_local()
                if not position then self:_failed(cycle);return end
                if not remote.conflict and sync:_compare_source(position,remote,context.chapters)=='same' then
                    self.cycle=nil;sync.dirty=false;sync:_discard_pending_upload(context.book_id)
                    sync:_mark_verified(context.book_id,'interval_positions_match',position,remote);return
                end
                if not remote.conflict and Readback.matches_normalized(cycle.baseline,remote) then
                    sync.remote_position=copy(remote)
                    local dispatched=sync:_upload_snapshot(position,'interval',false,nil,cycle)
                    if not dispatched and not sync.uploading then self:finish(cycle) end
                    return
                end
                -- Another client changed the cloud since the last decision. The
                -- timer cannot silently choose or navigate, even with ask=false.
                self.cycle=nil;sync:_clear_verified('interval_remote_changed')
                sync:_resolve(position,remote,context,{force_choice=true})
            end)
        end)
        if not ok then self:_failed(cycle) end
    end,{silent_offline=true})
    if not started and self:current(cycle) then self:_failed(cycle) end
end
return M
