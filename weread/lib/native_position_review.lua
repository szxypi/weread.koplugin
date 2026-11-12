-- Read-only recovery, with an opaque short-lived local archive choice.
local Access=require('weread.lib.native_read_access')
local C=require('weread.lib.native_position_contract')
local O=require('weread.lib.native_position_observation')
local Task=require('weread.lib.native_position_review_task')
local M={};M.__index=M
local function checked(fn) local ok,value=pcall(fn);return ok and value==true end
function M:new(options)
    return setmetatable({settings=assert(options.settings),client=assert(options.client),scheduler=assert(options.scheduler),
        credentials=options.credentials,journal=options.journal or require('weread.lib.native_position_store'):new(options.library,options.client),
        now=options.now or os.time,worker=options.worker,task=options.task or Task.run,
        guard_factory=options.guard_factory or function() return require('weread.lib.native_position_guard'):new() end},self)
end
function M:pending()
    local row,reason=self.journal:read();return row and row.phase~='idle' and row or nil,reason
end
function M:_current(job)
    local age=self.now()-job.started
    return self.context==job and age>=0 and age<=40 and checked(job.guard) and Access.matches(self.settings,job.access)
        and Task.current(self.journal,job.record)
        and (not job.observation or O.valid(job.observation) and O.hash(job.observation)==job.observation_hash)
end
function M:current(token)
    local job=self.context;return job and job.token==token and job.observation~=nil and self:_current(job) or false
end
function M:cancel()
    local job=self.context;self.context=nil;if not job then return end
    self.scheduler:unschedule(job.poll)
    if job.gate then job.gate:close() end
    if self.worker then self.worker:cancel() end
end
function M:on_view_changed() if self.context and not self:_current(self.context) then self:cancel() end end
function M:start(guard,callback,expected_record)
    if self.context then return false,'busy' end
    if type(guard)~='function' or type(callback)~='function' or not checked(guard) then return false,'unavailable' end
    local access=Access.capture(self.settings,self.credentials)
    if not access or access.renewal_pending then return false,'login' end
    local record,reason=self:pending()
    if not record then return false,reason or 'no_pending' end
    if expected_record and not Task.current(self.journal,expected_record) then return false,'changed' end
    if record.account~=C.account_key(access.scope.vid) then return false,'account_changed' end
    local opened,gate=pcall(self.guard_factory);if not opened or not gate then return false,'unavailable' end
    local job={record=record,access=access,guard=guard,started=self.now(),gate=gate};self.context=job
    job.poll=function()
        if self.context~=job then return end
        if not self:_current(job) then self:cancel();callback({kind='cancelled'});return end
        self.scheduler:scheduleIn(.1,job.poll)
    end
    self.scheduler:scheduleIn(.1,job.poll)
    local worker_ok,worker=pcall(function() return self.worker or require('weread.lib.memory_worker'):new{scheduler=self.scheduler,codec=self.client} end)
    if not worker_ok or not worker then self:cancel();return false,'unavailable' end
    self.worker=worker
    local task,client,settings,journal=self.task,self.client,self.settings,self.journal
    local ok,started=pcall(self.worker.start,self.worker,function() return task(client,settings,access,record,journal,gate) end,function(result)
        if self.context~=job then return end
        gate:close();job.gate=nil
        if not self:_current(job) then self:cancel();callback({kind='cancelled'});return end
        if type(result)~='table' or result.kind~='observed' or result.readbacks~=2 or not O.valid(result.observation)
            or result.observation.point.book_id~=record.metadata.book_id then
            local kind=type(result)=='table' and result.kind
            self:cancel();callback({kind=kind=='login' and 'login' or kind=='changed' and 'changed' or 'unavailable'});return
        end
        job.observation=client:json_decode(client:json_encode(result.observation));job.observation_hash=O.hash(job.observation);job.token={}
        callback({kind='observed',phase=record.phase,percent=job.observation.point.raw_percent},job.token)
    end)
    if not ok or not started then self:cancel();return false,'unavailable' end
    return true
end
function M:archive(token)
    local job=self.context
    if not self:current(token) then return false end
    local ok,archived=pcall(self.journal.archive,self.journal,job.record,job.observation)
    self:cancel();return ok and archived==true
end
return M
