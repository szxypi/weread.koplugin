-- A durable claim precedes the online single-write transaction. An interrupted
-- claim is never replayed: its request may already have reached the server.
local M={};M.__index=M
function M:new(options)
    return setmetatable({queue=assert(options.queue),service=assert(options.service),
        allowed=assert(options.allowed),cache=assert(options.cache),notify=options.notify},self)
end
function M:cancel()
    if not self.job then return end
    self.job=nil;self.service:cancel()
end
function M:pump()
    if self.job or not self.allowed() then return false end
    local entries=self.queue:list()
    if not entries then return false end
    for _,entry in ipairs(entries) do if entry.phase=='dispatching' then return false end end
    local entry
    for _,item in ipairs(entries) do if item.phase=='queued' then entry=item;break end end
    if not entry then return false end
    local pending,reason=self.service:pending()
    if pending or reason then return false end
    local job={entry=entry};self.job=job
    local function current() return self.job==job and self.allowed() end
    local function notify(phase,value)
        if self.notify then self.notify(phase,value or entry) end
    end
    local started,start_reason=self.service:prepare(entry.book_id,current,function(plan,why)
        if not current() then self:cancel();return end
        if not plan then
            self.job=nil;notify(why=='native_expired' and 'login' or 'unavailable');return
        end
        if plan.book_id~=entry.book_id or type(plan.before)~='boolean'
            or not self.service:preview_current(plan) then self:cancel();return end
        if plan.before==entry.desired then
            local saved=self.cache(plan.snapshot)
            local removed=saved and self.queue:remove(entry)
            self:cancel();notify(removed and 'confirmed' or 'unavailable');return
        end
        if plan.before~=entry.before or plan.operation~=(entry.desired and 'add' or 'remove') then
            local conflict=self.queue:transition(entry,'conflict')
            self:cancel();notify(conflict and 'conflict' or 'unavailable',conflict);return
        end
        local claim=self.queue:transition(entry,'dispatching')
        if not claim then self:cancel();notify('unavailable');return end
        job.claim=claim
        if not current() then self.queue:release_unsent(claim);self:cancel();return end
        local committed=self.service:commit(plan,function(result,finished)
            if not current() then self:cancel();return end
            self.job=nil
            local phase='unconfirmed'
            if finished and type(result)=='table' and (result.kind=='confirmed' or result.kind=='noop') then
                if self.cache(result.snapshot) and self.queue:remove(claim) then phase='confirmed' end
            elseif finished and type(result)=='table' and result.attempted==false then
                local released=self.queue:release_unsent(claim)
                if released then claim=released;phase=result.kind=='login' and 'login' or 'deferred' end
            end
            notify(phase,claim)
        end)
        if not committed then self.job=nil;notify('unconfirmed',claim) end
    end,false)
    if not started then self.job=nil;notify(start_reason=='login' and 'login' or 'unavailable');return false end
    return true
end
return M
