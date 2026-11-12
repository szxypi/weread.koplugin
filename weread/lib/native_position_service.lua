-- Parent owns native document guards; children only consult an anonymous bit
-- and durable account/journal state. No CRE/native document calls in workers.
local Access=require('weread.lib.native_read_access')
local Contract=require('weread.lib.native_position_contract')
local Protocol=require('weread.lib.native_position_protocol')
local Task=require('weread.lib.native_position_task')
local M={};M.__index=M
local function checked(callback) local ok,value=pcall(callback);return ok and value==true end
function M:new(options)
    return setmetatable({settings=assert(options.settings),client=assert(options.client),scheduler=assert(options.scheduler),credentials=options.credentials,
        journal=options.journal or require('weread.lib.native_position_store'):new(options.library,options.client),worker=options.worker,
        now=options.now or os.time,task_options=options.task_options or {},guard_factory=options.guard_factory or function() return require('weread.lib.native_position_guard'):new() end},self)
end
function M:pending()
    local value,reason=self.journal:read();return value and value.phase~='idle' and value or nil,reason
end
function M:_access()
    local selected=Access.capture(self.settings,self.credentials)
    return selected and not selected.renewal_pending and selected or nil
end
function M:_current(job)
    local now=self.now()
    return now>=job.started and now-job.started<=70 and Access.matches(self.settings,job.access) and checked(job.guard)
end
function M:_release(job)
    self.scheduler:unschedule(job.poll);job.gate:close()
    if self.job==job then self.job=nil end
end
function M:cancel()
    self.receipt=nil
    local job=self.job;if not job then return false end
    self:_release(job)
    if self.worker then self.worker:cancel() end
    if job.mode=='send' then self.journal:finish(job.record,'prepared') end
    return true
end
function M:on_view_changed()
    local job=self.job;if job and not self:_current(job) then self:cancel() end
end
local function shape(value,mode)
    return type(value)=='table' and ({confirmed=true,unconfirmed=true,noop=true,unavailable=true,login=true})[value.kind]
        and type(value.attempted)=='boolean' and type(value.acknowledged)=='boolean'
        and Protocol.integer(value.readbacks,0,mode=='resolve' and 2 or 4)
end
function M:_receipt(record,access)
    local token={};self.receipt={token=token,access=access,record=self.client:json_decode(self.client:json_encode(record))};return token
end
function M:accept(token)
    local receipt=self.receipt
    if not receipt or receipt.token~=token or not Access.matches(self.settings,receipt.access)
        or not self.journal:owns(receipt.record,'verified') then return false end
    if not self.journal:finish(receipt.record,'verified') then return false end
    self.receipt=nil;return true
end
function M:_start(mode,metadata,record,access,guard,callback)
    local ok,gate=pcall(self.guard_factory);if not ok or not gate then return false,'unavailable' end
    if mode=='send' then
        record=self.journal:begin(metadata,access.scope,record.revision)
        if not record then gate:close();return false,'storage' end
    end
    local job={mode=mode,record=record,access=access,guard=guard,gate=gate,started=self.now()};self.job=job
    job.poll=function()
        if self.job~=job then return end
        if not self:_current(job) then self:cancel();return end
        self.scheduler:scheduleIn(.1,job.poll)
    end
    self.scheduler:scheduleIn(.1,job.poll)
    local worker_ok,worker=pcall(function() return self.worker or require('weread.lib.memory_worker'):new{scheduler=self.scheduler,codec=self.client} end)
    if not worker_ok or not worker then self:cancel();return false,'unavailable' end
    self.worker=worker
    local options={};for key,value in pairs(self.task_options) do options[key]=value end
    -- Do not copy the parent's native-document guard into this callback.
    options.is_current=function() return gate:valid() end
    local called,started=pcall(self.worker.start,self.worker,function()
        if mode=='send' then return Task.run(self.client,self.settings,access,record,self.journal,options) end
        return Task.resolve(self.client,self.settings,access,record,self.journal,options)
    end,function(result)
        if self.job~=job then return end
        if not self:_current(job) then self:cancel();return end
        self:_release(job)
        local row=self.journal:read();local same=row and row.phase~='idle' and row.id==record.id and row.account==record.account
            and row.epoch==record.epoch and Contract.same(row.metadata,record.metadata)
        local valid=shape(result,mode)
        local expected_revision=record.revision+(mode=='send' and 3 or 1)
        if valid and result.kind=='confirmed' and result.acknowledged and same and row.phase=='verified'
            and row.revision==expected_revision and result.attempted==(mode=='send') and result.readbacks>=1 then
            callback(result,self:_receipt(row,access));return
        end
        if valid and not result.attempted and same and row.phase=='prepared' and mode=='send' then
            if result.kind~='noop' or Protocol.equal(row.metadata.before,row.metadata.desired) then self.journal:finish(row,'prepared') end
        end
        callback(valid and result.kind~='confirmed' and result or {kind='unconfirmed',attempted=true,acknowledged=false,readbacks=0})
    end)
    if not called or not started then
        if self.job==job then self:cancel() end
        return false,'unavailable'
    end
    return true
end
function M:start(metadata,guard,callback)
    if self.job or self.receipt then return false,'busy' end
    if type(guard)~='function' or type(callback)~='function' or not Contract.valid(metadata) or not checked(guard) then return false,'source_changed' end
    local access=self:_access();if not access then return false,'login' end
    local record,reason=self.journal:read();if not record then return false,reason end
    if record.phase~='idle' then return false,'pending' end
    local frozen=self.client:json_decode(self.client:json_encode(metadata))
    return self:_start('send',frozen,record,access,guard,callback)
end
function M:resolve(guard,callback)
    if self.job or self.receipt then return false,'busy' end
    if type(callback)~='function' then return false,'unavailable' end
    local access=self:_access();if not access then return false,'login' end
    local record,reason=self.journal:read();if not record then return false,reason end
    if record.phase=='idle' then return false,'no_pending' end
    if record.account~=Contract.account_key(access.scope.vid) then return false,'account_changed' end
    if record.phase=='verified' then
        callback({kind='completed',attempted=false,acknowledged=true,readbacks=0},self:_receipt(record,access));return true
    end
    if record.phase=='prepared' then
        if not self.journal:finish(record,'prepared') then return false,'storage' end
        callback({kind='aborted',attempted=false,acknowledged=false,readbacks=0});return true
    end
    if record.phase~='acknowledged' then return false,'unconfirmed' end
    if type(guard)~='function' or not checked(guard) then return false,'source_changed' end
    return self:_start('resolve',record.metadata,record,access,guard,callback)
end
return M
