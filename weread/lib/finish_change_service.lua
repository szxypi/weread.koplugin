-- Parent-owned preview, cache-before-finish and durable pending reconciliation.
local Access=require('weread.lib.native_read_access')
local Contract=require('weread.lib.finish_change_contract')
local Task=require('weread.lib.finish_change_task')
local M={};M.__index=M
function M:new(options)
    return setmetatable({settings=options.settings,client=options.client,scheduler=options.scheduler,store=options.credentials,
        journal=options.journal or require('weread.lib.finish_change_store'):new(options.library,options.client),
        persist=options.persist,worker=options.worker,now=options.now or os.time},self)
end
function M:pending()
    local record,reason=self.journal:read();return record and record.phase~='idle' and record or nil,reason
end
function M:cancel()
    local job=self.job;self.job,self.preview,self.preview_job=nil,nil,nil
    if self.worker then self.worker:cancel() end
    if job and job.record then self.journal:finish(job.record,'prepared') end
end
function M:current(job)
    return job.guard() and Access.matches(self.settings,job.access) and not job.access.renewal_pending
        and self.now()>=job.started and self.now()-job.started<=120
end
function M:_worker(task,callback)
    self.worker=self.worker or require('weread.lib.memory_worker'):new{scheduler=self.scheduler,codec=self.client,max_bytes=8*1024*1024}
    return self.worker:start(task,callback)
end
function M:prepare(id,guard,callback,resolving)
    if self.job or self.preview then return false,'busy' end
    local selected=Access.capture(self.settings,self.store);if not selected or selected.renewal_pending then return false,'login' end
    local record,reason=self.journal:read();if not record then return false,reason end
    if resolving then if record.phase=='idle' then return false,'no_pending' end;id=record.metadata.book_id
    elseif record.phase~='idle' then return false,'pending' end
    if not Contract.id(id) or not guard() then return false,'unavailable' end
    self.last_snapshot=nil
    local job={book_id=id,guard=guard,access=selected,started=self.now(),record=resolving and record or nil,revision=record.revision}
    self.job=job
    local called,started=pcall(self._worker,self,function()
        if not resolving then return Task.preview(self.client,self.settings,selected,id) end
        local observed=Task.inspect(self.client,self.settings,selected,id);local flags=Contract.flags(observed.raw);local row=flags[id]
        local read,point=pcall(Contract.point,observed.progress,id)
        return {metadata=record.metadata,observed=observed,current_present=row~=nil,current_finished=row and row.finished.value,
            position_unchanged=read and Contract.position_hash(point)==record.metadata.position_hash or false}
    end,function(plan)
        if self.job~=job then return end
        if not self:current(job) then self:cancel();callback(nil,'session_changed');return end
        self.job=nil
        if type(plan)~='table' or not Contract.valid_metadata(plan.metadata) or plan.metadata.book_id~=id or not plan.observed then callback(nil,'unavailable');return end
        local frozen={};for k,v in pairs(plan.metadata) do frozen[k]=v end
        job.metadata=frozen;job.observed=self.client:json_decode(self.client:json_encode(plan.observed));plan.resolving=resolving==true
        job.current_present,job.current_finished,job.position_unchanged=plan.current_present,plan.current_finished,plan.position_unchanged
        self.preview,self.preview_job=plan,job;callback(plan)
    end)
    if not called or not started then self:cancel();return false,'unavailable' end
    return true
end
function M:preview_current(plan)
    local job=self.preview_job
    return self.preview==plan and job and self:current(job) and Contract.same(plan.metadata,job.metadata)
        and plan.resolving==(job.record~=nil)
        and plan.current_present==job.current_present and plan.current_finished==job.current_finished and plan.position_unchanged==job.position_unchanged
end
function M:_save(observed)
    local ok,saved=pcall(self.persist,observed.snapshot)
    if ok and saved==true then self.last_snapshot=observed.snapshot;return true end
    return false
end
function M:accept_current(plan)
    if not self:preview_current(plan) or not self.preview_job.record or not self:_save(self.preview_job.observed) then return false end
    local record=self.preview_job.record;local finished=self.journal:finish(record,record.phase)
    if finished then self.preview,self.preview_job=nil,nil end;return finished
end
function M:commit(plan,callback)
    if self.job or not self:preview_current(plan) or self.preview_job.record then return false,'session_changed' end
    local job=self.preview_job;self.preview,self.preview_job=nil,nil
    local record=self.journal:begin(job.metadata,job.access.scope,job.revision);if not record then return false,'storage' end
    job.record=record;job.started=self.now();self.job=job
    local input={book_id=job.book_id,desired=job.metadata.desired}
    local called,started=pcall(self._worker,self,function()
        return Task.run(self.client,self.settings,job.access,input,record,self.journal)
    end,function(result)
        if self.job~=job then return end
        if not self:current(job) then self:cancel();callback({kind='unconfirmed',attempted=true},false);return end
        self.job=nil
        local valid=type(result)=='table' and result.book_id==job.book_id and type(result.attempted)=='boolean'
        local confirmed=false
        if valid and result.kind=='confirmed' and result.attempted and result.observed then
            local checked,value=pcall(Contract.check,result.observed.raw,result.observed.progress,record.metadata)
            confirmed=checked and value==true
        end
        local unsent=valid and not result.attempted and ({changed=true,login=true,unavailable=true})[result.kind]
        local noop=valid and not result.attempted and result.kind=='noop' and record.metadata.before_hash==record.metadata.after_hash
        if noop and result.observed then
            local checked,value=pcall(Contract.check,result.observed.raw,result.observed.progress,record.metadata)
            unsent=checked and value==true and self:_save(result.observed)
        end
        local finished=false
        if confirmed then finished=self:_save(result.observed) and self.journal:finish(record,'pending')
        elseif unsent then finished=self.journal:finish(record,'prepared') end
        callback(valid and result or {kind='unconfirmed',attempted=true},finished==true)
    end)
    if not called or not started then self:cancel();return false,'unavailable' end
    return true
end
return M
