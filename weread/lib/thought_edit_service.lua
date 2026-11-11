-- Parent owns draft persistence, previews and completion. Workers carry text
-- through anonymous pipes; the durable intent contains only typed digests.
local Access=require('weread.lib.native_read_access')
local Contract=require('weread.lib.thought_edit_contract')
local Thoughts=require('weread.lib.my_cloud_thoughts')
local Task=require('weread.lib.thought_edit_task')
local M={};M.__index=M
function M:new(options)
    return setmetatable({settings=assert(options.settings),client=assert(options.client),scheduler=assert(options.scheduler),
        journal=assert(options.journal),cache=assert(options.cache),worker=options.worker,credentials=options.credentials,
        now=options.now or os.time},self)
end
function M:pending()
    local record,reason=self.journal:read()
    return record and record.phase~='idle' and record or nil,reason
end
function M:cancel()
    local job=self.job or self.preview_job
    self.job,self.preview,self.preview_job=nil,nil,nil
    if self.worker then self.worker:cancel() end
    -- Atomic finish can win only before dispatch. A child that has already
    -- claimed the record leaves a pending operation for read-only recovery.
    if job and job.record and not job.resolving then self.journal:finish(job.record,'prepared') end
end
function M:current(job)
    return job and job.guard() and Access.matches(self.settings,job.access) and not job.access.renewal_pending
        and self.now()>=job.started and self.now()-job.started<=120
end
function M:_worker(task,callback)
    self.worker=self.worker or require('weread.lib.memory_worker'):new{scheduler=self.scheduler,codec=self.client,max_bytes=8*1024*1024}
    return self.worker:start(task,callback)
end
local function clone(self,value) return self.client:json_decode(self.client:json_encode(value)) end
function M:prepare(input,guard,callback,resolve)
    if self.job or self.preview then return false,'busy' end
    local access=Access.capture(self.settings,self.credentials)
    if not access or access.renewal_pending then return false,'login' end
    local record,reason=self.journal:read();if not record then return false,reason end
    if resolve then
        if record.phase=='idle' then return false,'no_pending' end
        input={book_id=record.metadata.book_id}
    elseif record.phase~='idle' then return false,'pending' end
    if not guard() then return false,'session_changed' end
    local copied,request=pcall(clone,self,input);if not copied or type(request)~='table' then return false,'invalid' end
    local job={input=request,guard=guard,access=access,started=self.now(),revision=record.revision,
        record=resolve and record or nil,resolving=resolve==true}
    self.job=job
    local called,started=pcall(self._worker,self,function()
        local ok,value
        if resolve then ok,value=pcall(Task.observe,self.client,self.settings,access,request.book_id)
        else ok,value=pcall(Task.preview,self.client,self.settings,access,request) end
        return ok and {value=value} or {reason=Task.expired(value) and 'native_expired' or 'changed'}
    end,function(result)
        if self.job~=job then return end
        if not self:current(job) then self:cancel();callback(nil,'session_changed');return end
        self.job=nil
        local value=type(result)=='table' and result.value
        local valid,snapshot=pcall(Thoughts.validate,self.client,resolve and value or type(value)=='table' and value.snapshot,request.book_id)
        if not valid or not resolve and (not Task.same(value.metadata,value.metadata)
            or not Contract.validate_body(request.operation,value.body) or Contract.body_hash(value.body)~=value.metadata.request_hash) then
            callback(nil,type(result)=='table' and result.reason or 'unavailable',access);return
        end
        job.snapshot=snapshot
        if not resolve then job.metadata=clone(self,value.metadata) end
        local confirmed=false
        if resolve then local ok,yes=pcall(Contract.check,snapshot,record.metadata);confirmed=ok and yes end
        local plan={book_id=request.book_id,operation=resolve and record.metadata.operation or request.operation,
            resolving=resolve==true,confirmed=confirmed,unsent=resolve==true and record.phase=='prepared'}
        job.display=clone(self,plan);self.preview,self.preview_job=plan,job;callback(plan)
    end)
    if not called or not started then self:cancel();return false,'unavailable' end
    return true
end
function M:preview_current(plan)
    local job=self.preview_job
    if self.preview~=plan or not self:current(job) then return false end
    for k,v in pairs(job.display) do if plan[k]~=v then return false end end
    for k,v in pairs(plan) do if job.display[k]~=v then return false end end
    return true
end
function M:_cache(snapshot,book)
    local ok,value=pcall(Thoughts.validate,self.client,snapshot,book)
    if not ok then return false end
    local saved,result=pcall(self.cache.write,self.cache,value)
    return saved and result==true
end
function M:resolve(plan,accept_current)
    local job=self.preview_job
    if not self:preview_current(plan) or not job.resolving then return false end
    if not plan.unsent and not plan.confirmed and accept_current~=true then return false end
    if not self:_cache(job.snapshot,job.input.book_id) then return false end
    local phase=plan.unsent and 'prepared' or 'pending'
    local finished=self.journal:finish(job.record,phase,not plan.confirmed)
    self.preview,self.preview_job=nil,nil
    return finished,job.snapshot
end
function M:commit(plan,callback)
    if self.job or not self:preview_current(plan) or self.preview_job.resolving then return false,'session_changed' end
    local job=self.preview_job;self.preview,self.preview_job=nil,nil
    local record=self.journal:begin(job.metadata,job.access.scope,job.revision,job.input.draft)
    if not record then return false,'storage' end
    job.record,job.started=record,self.now();self.job=job
    local called,started=pcall(self._worker,self,function()
        return Task.run(self.client,self.settings,job.access,job.input,record,self.journal)
    end,function(result)
        if self.job~=job then return end
        if not self:current(job) then self:cancel();callback({kind='unconfirmed'},false);return end
        self.job=nil
        local prepared=self.journal:owns(record,'prepared')
        local finished=false
        if prepared then finished=self.journal:finish(record,'prepared')
        elseif self.journal:owns(record,'pending') and type(result)=='table' and result.kind=='confirmed' then
            local ok,snapshot=pcall(Thoughts.validate,self.client,result.snapshot,job.input.book_id)
            local checked,confirmed=false,false
            if ok then checked,confirmed=pcall(Contract.check,snapshot,job.metadata) end
            if checked and confirmed and self:_cache(snapshot,job.input.book_id) then finished=self.journal:finish(record,'pending') end
        end
        callback(type(result)=='table' and result or {kind='unconfirmed'},finished==true)
    end)
    if not called or not started then self:cancel();return false,'unconfirmed' end
    return true
end
return M
