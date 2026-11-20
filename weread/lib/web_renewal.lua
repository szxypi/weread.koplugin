-- Parent-only intent/receipt/credential commits with one POST per durable intent.
local Auth=require('weread.lib.web_authorization')
local Store=require('weread.lib.web_renewal_store')
local Worker=require('weread.lib.memory_worker')
local M={};M.__index=M
function M:new(options)
    return setmetatable({settings=assert(options.settings),client=assert(options.client),scheduler=assert(options.scheduler),
        store=options.store or Store:new(options.settings,options.client),worker=options.worker},self)
end
function M:cancel(expected)
    local job=self.job;if not job or expected and expected~=job then return end
    self.job=nil;if self.worker then self.worker:cancel() end
    job.candidate,job.callback=nil,nil
end
function M:_current(job)
    if self.job~=job or job.is_current and not job.is_current() or not self.settings:auth_scope_matches(job.input.scope) then return false end
    local record=self.store:read()
    if not record then return false end
    local receipt=job.candidate and job.verified
    if record.revision~=job.record.revision then
        if not job.candidate or record.revision~=job.record.revision+1 or record.scope.vid~=job.input.scope.vid
            or record.scope.epoch~=job.input.scope.epoch then return false end
        local staged=record.phase==(job.verified and 'verified' or 'candidate') and record.input_revision==job.input.revision
            and record.target_revision==job.candidate.revision
        local completed=receipt and record.phase=='done' and record.input_revision==job.candidate.revision
        if not staged and not completed then return false end
    end
    local ok,memory,disk=pcall(function() return Auth.memory(self.settings),Auth.primary(self.settings) end)
    local function allowed(value)
        return value and value.scope.vid==job.input.scope.vid and value.scope.epoch==job.input.scope.epoch
            and (value.revision==job.input.revision or receipt and value.revision==job.candidate.revision)
    end
    return ok and allowed(memory) and allowed(disk)
end
function M:_finish(job,ok,reason,retain)
    if self.job~=job then return end
    local callback=job.callback;job.callback=nil
    if not retain then self:cancel(job) end
    if callback then callback(ok,reason) end
end
function M:_persist(job)
    if not self:_current(job) then self:_finish(job,false,'session_changed');return end
    local actual=self.store:read()
    if job.verified and actual.phase=='done' and actual.input_revision==job.candidate.revision then
        local completed,current=pcall(function()
            assert(self.store.sync(self.store.path)==true and self.store.sync(self.settings.settings_file)==true)
            local value=Auth.capture(self.settings);assert(value.revision==job.candidate.revision);return value
        end)
        if completed then self:_finish(job,true,current)
        else job.state='save_failed';self:_finish(job,false,'save_failed',true) end
        return
    end
    job.record=actual
    local record,reason=self.store:receipt(job.input,job.record,job.candidate,job.verified)
    if not record then
        if reason=='session_changed' or reason=='replaced' then self:_finish(job,false,'session_changed')
        else job.state='save_failed';self:_finish(job,false,'save_failed',true) end
        return
    end
    job.record=record
    if not job.verified then self:_finish(job,false,'verification_unconfirmed');return end
    local saved,value=self.store:apply(job.input,job.record)
    if saved then self:_finish(job,true,value)
    elseif value=='session_changed' or value=='replaced' then self:_finish(job,false,'session_changed')
    else job.state='save_failed';self:_finish(job,false,'save_failed',true) end
end
function M:_run(job,candidate)
    if not self:_current(job) then
        if not candidate and Auth.current(self.settings,job.input) then self.store:release(job.input,job.record) end
        self:_finish(job,false,'session_changed');return
    end
    if not self.worker then
        local ok,worker=pcall(Worker.new,Worker,{scheduler=self.scheduler,codec=self.client})
        if not ok then
            if not candidate then self.store:release(job.input,job.record) end
            self:_finish(job,false,'not_dispatched');return
        end
        self.worker=worker
    end
    local called,started=pcall(self.worker.start,self.worker,function() return Auth.run(self.client,job.input,candidate) end,function(result)
        if not self:_current(job) then self:_finish(job,false,'session_changed');return end
        if type(result)~='table' or type(result.attempted)~='boolean' or type(result.ok)~='boolean' then
            self:_finish(job,false,'renewal_unconfirmed');return
        end
        if result.candidate then
            local valid,value=pcall(Auth.snapshot,result.candidate,job.input.scope)
            if not valid then self:_finish(job,false,'renewal_unconfirmed');return end
            job.candidate=value;job.verified=result.ok==true
            if job.verified and (type(result.book_count)~='number' or result.book_count%1~=0 or result.book_count<0 or result.book_count>5000) then
                self:_finish(job,false,'renewal_unconfirmed');return
            end
            self:_persist(job)
        else
            if not result.attempted and not candidate then self.store:release(job.input,job.record) end
            self:_finish(job,false,result.attempted and 'renewal_unconfirmed' or 'not_dispatched')
        end
    end)
    if not called or not started then
        local dispatched=self.worker.job~=nil
        if dispatched then self.worker:cancel() end
        if not candidate and not dispatched then self.store:release(job.input,job.record) end
        self:_finish(job,false,dispatched and 'renewal_unconfirmed' or 'not_dispatched')
    end
end
function M:start(options,callback)
    options=options or {}
    if options.is_current and not options.is_current() then return false,'session_changed' end
    local old=self.job
    if old then
        if old.state~='save_failed' then return false,'busy' end
        if not self:_current(old) then self:cancel(old);return false,'session_changed' end
        old.callback=callback;self:_persist(old);return true,old
    end
    local valid,input=pcall(Auth.capture,self.settings)
    if not valid then
        -- A committed auth file may precede the final intent receipt on disk.
        -- Only an already-verified, same-scope receipt may align that memory.
        local record=self.store:read()
        local aligned,result=pcall(self.store.align,self.store,record)
        if not aligned or not result then return false,'session_changed' end
        valid,input=pcall(Auth.capture,self.settings)
    end
    if not valid or options.expected_revision and input.revision~=options.expected_revision then return false,'session_changed' end
    local record,reason=self.store:begin(input)
    if not record then return false,reason end
    local job={input=input,record=record,callback=callback,is_current=options.is_current};self.job=job
    self:_run(job,reason=='resume' and record.candidate or nil)
    return true,job
end
return M
