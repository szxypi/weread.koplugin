-- Observe the existing local collector before a cloud comparison. This owns
-- only a bounded timer; it never starts network work or captures native text.
local M={TIMEOUT=35}
local working={waiting=true,preparing=true,deferred=true}
local function available(sync,job)
    local point=sync.get_source_position and sync.get_source_position()
    return type(point)=='table' and point.book_id==job.scope.book_id
end
function M.cancel(sync,job)
    local wait=job and job.source_wait
    if not wait then return end
    job.source_wait=nil;sync.scheduler:unschedule(wait.expire)
end
function M.start(sync,job,current,proceed,failed)
    if not sync.prepare_upload or not sync.get_source_position or available(sync,job) or not working[sync.source_state] then return false end
    local wait={started=sync.now()};job.source_wait=wait
    local function owned()
        if job.source_wait~=wait then return false end
        if current() then return true end
        M.cancel(sync,job);return false
    end
    wait.wake=function()
        if not owned() then return end
        if available(sync,job) then M.cancel(sync,job);proceed()
        elseif not working[sync.source_state] then
            local quiet=sync.source_state=='paused' or sync.source_state=='idle'
            M.cancel(sync,job);failed(quiet and 'source_cancelled' or 'source_position_unavailable',quiet)
        end
    end
    wait.expire=function()
        if not owned() then return end
        local elapsed=sync.now()-wait.started
        if elapsed>=0 and elapsed<M.TIMEOUT then sync.scheduler:scheduleIn(M.TIMEOUT-elapsed,wait.expire);return end
        M.cancel(sync,job);failed('source_preparation_timeout',false)
    end
    sync.scheduler:scheduleIn(M.TIMEOUT,wait.expire)
    return true
end
function M.changed(sync)
    local wait=sync.pull_job and sync.pull_job.source_wait
    if wait then wait.wake() end
end
return M
