-- Parent-owned previews, explicit dispatch and durable no-replay coordination.
local Access=require('weread.lib.native_read_access')
local Task=require('weread.lib.shelf_membership_write')
local Worker=require('weread.lib.memory_worker')
local Journal=require('weread.lib.shelf_membership_journal')
local M={};M.__index=M
function M:new(options)
    return setmetatable({settings=assert(options.settings),client=assert(options.client),scheduler=assert(options.scheduler),
        journal=options.journal or Journal:new(options.settings,options.client),worker=options.worker,now=options.now or os.time,
        store=options.store},self)
end
function M:pending()
    local scope=self.settings:get_auth_scope();local record,reason=self.journal:read(scope)
    return record and record.phase=='pending' and record or nil,reason
end
function M:cancel()
    self.preview,self.preview_job=nil,nil;self.job=nil
    if self.worker then self.worker:cancel() end
end
function M:current(job)
    return self.job==job and job.guard() and Access.matches(self.settings,job.access)
        and not job.access.renewal_pending and self.now()>=job.started and self.now()-job.started<=120
end
function M:_worker(task,callback)
    self.worker=self.worker or Worker:new{scheduler=self.scheduler,codec=self.client,max_bytes=8*1024*1024}
    return self.worker:start(task,callback)
end
function M:prepare(book_id,guard,callback,resolve)
    if self.job or self.preview then return false,'busy' end
    local selected=Access.capture(self.settings,self.store)
    if not selected or selected.renewal_pending then return false,'login' end
    local record,reason=self.journal:read(selected.scope)
    if not record then return false,reason end
    if resolve then
        if record.phase~='pending' then return false,'no_pending' end
        book_id=record.book_id
    elseif record.phase=='pending' then return false,'pending' end
    if not Task.book_id(book_id) or not guard() then return false,'unavailable' end
    local job={book_id=book_id,guard=guard,access=selected,started=self.now(),record=resolve and record or nil}
    self.job=job
    local called,started=pcall(self._worker,self,function() return {snapshot=Task.fetch(self.client,self.settings,selected)} end,function(result)
        if not self:current(job) then if self.job==job then self:cancel();callback(nil,'session_changed') end;return end
        self.job=nil
        local snapshot=type(result)=='table' and result.snapshot
        local members=Task.members(snapshot)
        if not members then callback(nil,'unavailable');return end
        local plan={snapshot=snapshot,book_id=book_id,before=Task.contains(snapshot,book_id),resolving=resolve==true}
        plan.operation=plan.before and 'remove' or 'add'
        job.input={book_id=book_id,before=plan.before,operation=plan.operation,members=members,members_digest=Task.digest(members)}
        self.preview,self.preview_job=plan,job;callback(plan)
    end)
    if not called or not started then self:cancel();return false,'unavailable' end
    return true
end
function M:preview_current(plan)
    local job=self.preview_job
    return self.preview==plan and job and job.guard() and Access.matches(self.settings,job.access)
        and not job.access.renewal_pending and self.now()>=job.started and self.now()-job.started<=120
        and plan.book_id==job.input.book_id and plan.before==job.input.before and plan.operation==job.input.operation
        and plan.resolving==(job.record~=nil)
end
function M:accept_current(plan)
    local job=self.preview_job
    if not self:preview_current(plan) or not job.record then return false end
    local ok=self.journal:finish(job.access.scope,job.record)
    self.preview,self.preview_job=nil,nil;return ok
end
function M:commit(plan,callback)
    if self.job or not self:preview_current(plan) or self.preview_job.record then return false,'session_changed' end
    local job=self.preview_job
    self.preview,self.preview_job=nil,nil
    local input=job.input
    local record=self.journal:begin(job.access.scope,input.book_id,input.operation)
    if not record then return false,'storage' end
    self.job=job;job.record,job.started=record,self.now()
    local selected,settings,journal=job.access,self.settings,self.journal
    local called,started=pcall(self._worker,self,function()
        return Task.run(self.client,settings,selected,input,function() return journal:owns(selected.scope,record) end)
    end,function(result)
        if not self:current(job) then
            if self.job==job then self:cancel();callback({kind='unconfirmed',attempted=true},false) end
            return
        end
        self.job=nil
        local valid=type(result)=='table' and result.book_id==input.book_id and result.operation==input.operation
            and type(result.attempted)=='boolean'
        local observed_members=valid and Task.members(result.snapshot)
        local confirmed=valid and observed_members and result.attempted and result.confirmed==true and result.acknowledged==true
            and Task.contains(result.snapshot,input.book_id)==(input.operation=='add')
            and Task.digest(observed_members)==Task.expected(input)
        local unsent=valid and result.attempted==false and ({noop=true,changed=true,unavailable=true})[result.kind]
        local finished=(confirmed or unsent) and journal:finish(selected.scope,record)
        callback(valid and result or {kind='unconfirmed',attempted=true},finished==true)
    end)
    if not called or not started then self:cancel();return false,'unconfirmed' end
    return true
end
return M
