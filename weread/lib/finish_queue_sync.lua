-- Reuse the online single-write transaction for each offline intent. A queue
-- claim is persisted before commit; a crash leaves it for explicit review.
local M={};M.__index=M
function M:new(options)
    return setmetatable({queue=options.queue,service=options.service,allowed=options.allowed,notify=options.notify},self)
end
function M:cancel()
    if not self.job then return end
    self.job=nil;self.service:cancel()
end
function M:pump()
    if self.job or not self.allowed() then return false end
    local entries=self.queue:list()
    if not entries then return false end
    -- A possibly dispatched record must be reconciled before another write.
    for _,entry in ipairs(entries) do if entry.phase=='dispatching' then return false end end
    local entry
    for _,item in ipairs(entries) do if item.phase=='queued' then entry=item;break end end
    if not entry then return false end
    local pending,reason=self.service:pending()
    if pending or reason then return false end
    local job={entry=entry};self.job=job
    local function current() return self.job==job and self.allowed() end
    local started=self.service:prepare(entry.book_id,current,function(plan)
        if not current() then self:cancel();return end
        if not plan then self.job=nil;if self.notify then self.notify('unavailable',entry) end;return end
        local metadata=plan.metadata
        if not metadata or metadata.book_id~=entry.book_id or metadata.desired~=entry.desired
            or not self.service:preview_current(plan) then self:cancel();return end
        if metadata.before~=entry.before and metadata.before~=entry.desired then
            local conflict=self.queue:transition(entry,'conflict')
            self:cancel();if self.notify then self.notify('conflict',conflict or entry) end;return
        end
        local claim=self.queue:transition(entry,'dispatching')
        if not claim then self:cancel();return end
        job.claim=claim
        if not current() then
            self.queue:release_unsent(claim);self:cancel();return
        end
        local committed=self.service:commit(plan,function(result,finished)
            if not current() then self:cancel();return end
            self.job=nil
            local phase='unconfirmed'
            if finished and type(result)=='table' and (result.kind=='confirmed' or result.kind=='noop') then
                if self.queue:remove(claim) then phase='confirmed' end
            elseif finished and type(result)=='table' and result.attempted==false then
                if self.queue:release_unsent(claim) then phase='deferred' end
            end
            if self.notify then self.notify(phase,claim) end
        end)
        if not committed then
            -- commit failure before worker startup cancels its prepared journal;
            -- its implementation cannot prove whether a worker began here.
            self.job=nil
            if self.notify then self.notify('unconfirmed',claim) end
        end
    end,false,entry.desired)
    if not started then self.job=nil;return false end
    return true
end
return M
