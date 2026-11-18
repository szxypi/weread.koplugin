-- Parent guards the view; a child consults only an anonymous cancellation bit.
local C=require('weread.lib.readtime_transfer_contract')
local Native=require('weread.lib.native_read_access')
local Web=require('weread.lib.read_access')
local Account=require('weread.lib.native_position_contract').account_key
local Task=require('weread.lib.readtime_transfer_task')
local M={};M.__index=M
local function checked(fn) local ok,v=pcall(fn);return ok and v==true end
function M:new(options)
    return setmetatable({settings=assert(options.settings),client=assert(options.client),journal=assert(options.journal),
        scheduler=assert(options.scheduler),worker=options.worker,credentials=options.credentials,acquire=assert(options.acquire),
        now=options.now or os.time,task_options=options.task_options or {},
        guard_factory=options.guard_factory or function() return require('weread.lib.native_position_guard'):new() end},self)
end
function M:_current(job)
    local age=self.now()-job.started
    return self.job==job and age>=0 and age<=70 and checked(job.guard)
        and (not job.native or Native.matches(self.settings,job.native) and Web.matches(self.settings,job.web))
end
function M:_release(job,resume)
    job.gate:close();self.scheduler:unschedule(job.poll)
    if self.job==job then self.job=nil end
    job.release(resume)
end
function M:cancel()
    local job=self.job;if not job then return false end
    local resume=self:_current(job)
    -- Invalidate dispatch first, then kill/reap; claimed intervals stay sealed.
    job.gate:close()
    if self.worker then self.worker:cancel() end
    self:_release(job,resume);return true
end
function M:start(mode,account,input,references,guard,callback)
    if self.job then return false,'busy' end
    if not ({send=true,resolve=true,recover=true,retire=true})[mode] or not C.account(account)
        or type(input)~='table' or type(guard)~='function' or type(callback)~='function' or not checked(guard) then return false,'unavailable' end
    local native,web
    if mode=='send' or mode=='resolve' then
        native=Native.capture(self.settings,self.credentials);web=Web.capture(self.settings)
        if not native or native.renewal_pending or not web or not web.web then return false,'login' end
        if Account(native.scope.vid)~=account then return false,'account_changed' end
    end
    local pending,reason=self.journal:pending(account)
    if reason then return false,'storage' end
    if mode=='send' then if pending then return false,'pending' end
    elseif not pending or pending.attempt~=input.attempt or not self.journal:owns(input) then return false,'replaced' end
    if mode=='resolve' and pending.phase~='acknowledged' then return false,'unconfirmed' end
    if mode=='recover' and pending.phase~='prepared' and pending.phase~='confirmed' then return false,'unconfirmed' end
    if mode=='retire' and (pending.phase=='prepared' or pending.phase=='confirmed' and pending.evidence) then return false,'unconfirmed' end
    local copied,frozen,refs=pcall(function()
        return self.client:json_decode(self.client:json_encode(input)),
            references and self.client:json_decode(self.client:json_encode(references))
    end)
    if not copied then return false,'unavailable' end
    local made,gate=pcall(self.guard_factory);if not made or not gate then return false,'unavailable' end
    local acquired,release,why=pcall(self.acquire,input.book_id or input.metadata and input.metadata.book_id)
    if not acquired or type(release)~='function' then gate:close();return false,why or 'busy' end
    local job={native=native,web=web,guard=guard,gate=gate,release=release,started=self.now()};self.job=job
    job.poll=function()
        if self.job~=job then return end
        if not self:_current(job) then
            self:cancel();callback({kind='cancelled'});return
        end
        self.scheduler:scheduleIn(.1,job.poll)
    end
    self.scheduler:scheduleIn(.1,job.poll)
    local worker_ok,worker=pcall(function() return self.worker or require('weread.lib.memory_worker'):new{scheduler=self.scheduler,codec=self.client} end)
    if not worker_ok or not worker then self:cancel();return false,'unavailable' end
    self.worker=worker
    local options={};for k,v in pairs(self.task_options) do options[k]=v end
    options.account=account;options.is_current=function() return gate:valid() end
    local ran,started=pcall(worker.start,worker,function()
        if mode=='send' then return Task.run(self.client,self.settings,native,web,frozen,refs,self.journal,options) end
        if mode=='resolve' then return Task.resolve(self.client,self.settings,native,web,frozen,refs,self.journal,options) end
        assert(gate:valid(),'cancelled')
        local saved=mode=='recover' and self.journal:recover(account,frozen) or mode=='retire' and self.journal:retire_unknown(frozen)
        return {kind=saved and 'completed' or 'unavailable'}
    end,function(result)
        if self.job~=job then return end
        if not self:_current(job) then self:cancel();callback({kind='cancelled'});return end
        self:_release(job,true)
        local valid=type(result)=='table' and ({confirmed=true,saved_confirmation=true,unconfirmed=true,unavailable=true,
            unsupported_source=true,login=true,completed=true})[result.kind]
        if valid and (result.kind=='confirmed' or result.kind=='saved_confirmation') then
            local row=self.journal:get(account,result.attempt)
            valid=row and (row.phase=='settled' or row.phase=='confirmed') and row.evidence and row.evidence.audit
                and row.evidence.audit.seconds==row.metadata.seconds and row.metadata.book_id==(frozen.book_id or frozen.metadata.book_id)
        end
        callback(valid and result or {kind='unconfirmed'})
    end)
    if not ran or not started then if self.job==job then self:cancel() end;return false,'unavailable' end
    return true
end
return M
