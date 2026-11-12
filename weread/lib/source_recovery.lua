-- A source read may recover once through the existing parent-owned renewal
-- service. Adopt only its verified, same-login receipt, never child cookies.
local Access=require('weread.lib.read_access')
local Auth=require('weread.lib.web_authorization')
local M={};M.__index=M
local function gateway(selected)
    return selected and selected.gateway and selected.gateway.api_key
end
function M:new(options)
    return setmetatable({settings=assert(options.settings),renew=assert(options.renew),cancel_renewal=assert(options.cancel),
        can_recover=options.can_recover or function() return true end},self)
end
function M:cancel(job)
    if not job or self.job~=job then return end
    self.job=nil;job.callback=nil
    if job.handle then self.cancel_renewal(job.handle) end
end
function M:_current(job)
    if self.job~=job or not job.is_current() or not self.can_recover(job.book_id)
        or not self.settings:auth_scope_matches(job.scope) then return false end
    local current=Access.capture(self.settings)
    return current and current.web and current.web.cookies.wr_vid == job.scope.vid
        and gateway(current)==gateway(job.access) or false
end
function M:start(book_id,access,is_current,callback)
    if self.job or not self.can_recover(book_id) or not Access.matches(self.settings,access)
        or not access.web or not is_current() then return false end
    -- Pin the caller's memory scope here. The renewal service owns primary
    -- validation and may align a verified receipt after an interrupted save;
    -- requiring equal primary/memory revisions here would prevent that repair.
    local ok,input=pcall(Auth.memory,self.settings)
    if not ok or input.scope.vid~=access.web.cookies.wr_vid then return false end
    local job={book_id=book_id,access=access,scope=input.scope,is_current=is_current,callback=callback};self.job=job
    local function finish(success,receipt)
        if self.job~=job then return end
        local valid=self:_current(job)
        local accepted=success and valid and type(receipt)=='table' and type(receipt.scope)=='table'
            and receipt.scope.vid==job.scope.vid and receipt.scope.epoch==job.scope.epoch
            and Auth.current(self.settings,receipt)
        local fresh=accepted and Access.capture(self.settings)
        local done=job.callback;self:cancel(job)
        if done then
            if fresh then done(fresh) else done(nil,'source_authentication_unavailable') end
        end
    end
    local called,started,handle=pcall(self.renew,{is_current=function() return self:_current(job) end},finish)
    if self.job==job then
        if called and started then job.handle=handle
        else self:cancel(job);return false end
    elseif called and started then self.cancel_renewal(handle) end
    return true,job
end
return M
