-- Parent-owned adoption of one verified native renewal. No document guard is
-- passed to a renewal child; cancellation leaves its durable unknown marker.
local Access=require('weread.lib.native_read_access')
local M={};M.__index=M
local function checked(fn) local ok,v=pcall(fn);return ok and v==true end
function M:new(options)
    return setmetatable({settings=assert(options.settings),client=assert(options.client),scheduler=assert(options.scheduler),
        renewal=options.renewal},self)
end
function M:cancel(expected)
    local job=self.job;if not job or expected and job~=expected then return end
    self.job=nil;job.callback=nil
    -- The account settings UI can retry this verified save without a new POST.
    if job.handle and not (job.service.job==job.handle and job.handle.state=='save_failed') then job.service:cancel(job.handle) end
end
function M:start(selected,is_current,callback)
    if self.job or not selected or selected.renewal_pending or not Access.matches(self.settings,selected)
        or type(callback)~='function' or not checked(is_current) then return false end
    local service=self.renewal or require('weread.lib.native_renewal'):new{
        settings=self.settings,client=self.client,scheduler=self.scheduler,store=selected.store}
    local job={service=service,callback=callback};self.job=job
    local function complete(success)
        if self.job~=job then return end
        local fresh=Access.capture(self.settings,selected.store)
        local accepted=success and checked(is_current) and self.settings:auth_scope_matches(selected.scope)
            and fresh and not fresh.renewal_pending and fresh.revision==selected.revision+2
            and fresh.scope.vid==selected.scope.vid and fresh.scope.epoch==selected.scope.epoch
            and fresh.credentials.deviceId==selected.credentials.deviceId
        local done=job.callback;self:cancel(job)
        if done then done(accepted and fresh or nil,not accepted and 'source_native_authentication_unavailable' or nil) end
    end
    local called,started,handle=pcall(service.start,service,{expected_revision=selected.revision},complete)
    if self.job==job then
        if called and started then job.handle=handle else self:cancel(job);return false end
    elseif called and started then service:cancel(handle) end
    return true,job
end
return M
