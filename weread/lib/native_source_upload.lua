-- Parent-owned TXT preparation and asynchronous zero-time sender. The native
-- journal owns dispatch/ACK recovery; the Web time reporter never receives it.
local Access=require('weread.lib.native_read_access')
local P=require('weread.lib.native_position_protocol')
local C=require('weread.lib.native_position_contract')
local Snapshot=require('weread.lib.native_position_snapshot')
local Same=require('weread.lib.source_upload_candidate').same
local M={};M.__index=M
local fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
local function copy(v) if type(v)~='table' then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local function same(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for _i,k in ipairs(fields) do if a[k]~=b[k] then return false end end;return true
end
function M:new(options)
    local source=assert(options.source);local client=assert(source.client);local settings=assert(client.settings)
    return setmetatable({source=source,client=client,settings=settings,scheduler=assert(options.scheduler),
        credentials=options.credentials,now=options.now or os.time,worker=options.worker,
        service=options.service or require('weread.lib.native_position_service'):new{settings=settings,client=client,
            library=options.library or require('weread.lib.library_db'):new(settings),scheduler=options.scheduler,credentials=options.credentials},
        make_gate=options.make_gate or function() return require('weread.lib.native_position_guard'):new() end,
        snapshot=options.snapshot or Snapshot.run,recovery=options.recovery},self)
end
function M:_current(job)
    local age=self.now()-job.started
    return self.job==job and age>=0 and age<=90 and self.source.is_online() and self.source:_current(job.scope)
        and (not job.deadline or self.now()<=job.deadline)
        and same(self.source:current(),job.point)
        and (not job.receipt or self.source:is_current_native_preview(job.receipt,job.candidate))
        and (not job.access or job.recovering and self.settings:auth_scope_matches(job.access.scope) or Access.matches(self.settings,job.access))
        and (not job.plan or job.plan.basis=='raw_txt_utf16' and job.plan.transport=='native_position'
            and Same(job.plan.position,job.wire) and same(job.plan.source_position,job.point) and job.plan.deadline==job.deadline)
end
function M:_close(job)
    if self.job~=job then return end
    self.job=nil;self.scheduler:unschedule(job.poll)
    if job.renewal and self.recovery then self.recovery:cancel(job.renewal);job.renewal=nil end
    if job.gate then job.gate:close();job.gate=nil end
    if self.worker then self.worker:cancel() end
    if self.service.job then self.service:cancel() end
    if self.source.preview_token==job.source_token then self.source:cancel_upload_preview() end
end
function M:cancel()
    local job=self.job
    if not job then
        -- A delivered result can leave an in-memory receipt after local save
        -- failure. Drop that handle on review/cancel; its durable journal row
        -- stays available for an explicit fresh check.
        return self.service:cancel()
    end
    if job.stage=='delivering' then job.release_requested=true;return true end
    local complete=job.completion;job.completion=nil
    self:_close(job)
    if job.callback then local cb=job.callback;job.callback=nil;cb(nil,'source_cancelled') end
    if complete then
        local record,reason=self.service:pending()
        local unknown=record~=nil or reason~=nil or not job.recovering and not Access.matches(self.settings,job.access)
        complete(true,false,{accepted=false,acknowledged=false,position_confirmed=false,
            enter_attempted=false,report_attempted=unknown,error_kind=unknown and 'unconfirmed' or 'position',
            error=unknown and 'upload_readback_unconfirmed' or 'source_cancelled'})
    end
    return true
end
function M:on_view_changed() if self.job and not self:_current(self.job) then self:cancel() end end
function M:_fail(job,reason)
    if self.job~=job then return end
    local cb,complete=job.callback,job.completion;job.callback,job.completion=nil,nil;self:_close(job)
    if cb then cb(nil,reason) end
    if complete then complete(true,false,{accepted=false,acknowledged=false,position_confirmed=false,enter_attempted=false,
        report_attempted=false,error_kind='position',error=reason}) end
end
function M:_retire_completed()
    if self.service.job then return false end
    local record,reason=self.service:pending()
    if reason then return false end
    if not record then return true end
    if record.phase~='verified' and record.phase~='prepared' then return false end
    -- Retire only a past verified operation, without claiming it is still the
    -- current cloud point or applying its source position to this reader.
    self.service:cancel()
    local accepted=false
    self.service:resolve(nil,function(result,token)
        if result.kind=='completed' then accepted=self.service:accept(token)
        elseif result.kind=='aborted' then accepted=true end
    end)
    return accepted
end
local function outcome(result,metadata)
    local confirmed=result.kind=='confirmed' and result.acknowledged==true
    local noop=result.kind=='noop' and result.attempted==false and P.equal(metadata.before,metadata.desired)
    local out={accepted=confirmed or noop,acknowledged=result.acknowledged==true,position_confirmed=confirmed or noop,
        read_only_confirmation=noop,
        enter_attempted=false,report_attempted=result.attempted==true,error_kind='unconfirmed',error='upload_readback_unconfirmed'}
    if confirmed or noop then
        local p=metadata.desired
        out.remote={book_id=p.book_id,chapter_uid=p.chapter_uid,chapter_idx=p.chapter_idx,chapter_offset=p.chapter_offset,
            percent=p.raw_percent,raw_percent=p.raw_percent,has_chapter_offset=true,has_chapter_index=true,source='native'}
        out.error,out.error_kind=nil,nil
    elseif not result.attempted then
        out.error_kind='position';out.error=result.kind=='login' and 'source_native_authentication_unavailable' or 'source_position_changed'
    end
    return out
end
function M:_plan(job,metadata)
    job.stage,job.metadata='ready',copy(metadata)
    job.wire={book_id=job.candidate.book_id,chapter_uid=job.candidate.chapter_uid,chapter_idx=job.candidate.chapter_idx,
        chapter_offset=job.candidate.chapter_offset,percent=job.candidate.raw_percent,summary=job.candidate.summary}
    local plan={position=copy(job.wire),source_position=copy(job.point),basis='raw_txt_utf16',transport='native_position',deadline=job.deadline}
    job.plan=plan
    plan.is_current=function() return not job.recovering and job.receipt~=nil and self:_current(job) end
    plan.release=function() if self.job==job then self:cancel() end end
    plan.dispatch=function(callback)
        if job.dispatched or not self:_current(job) then return false,'source_position_changed' end
        job.dispatched,job.stage,job.completion=true,'sending',callback
        return self:_send(job)
    end

    local cb=job.callback;job.callback=nil;cb(plan)
end
function M:prepare(intent,callback)
    assert(type(callback)=='function')
    if self.job and self.job.stage=='delivering' then callback(nil,'source_busy');return false end
    self:cancel()
    if type(intent)~='table' then callback(nil,'source_position_changed');return false end
    intent=copy(intent)
    local point=type(intent)=='table' and intent.source_position
    local scope=type(point)=='table' and self.source:_live()
    if not scope or point.basis~='raw_txt_utf16' or point.upload_verified~=false or point.book_id~=intent.book_id
        or not same(point,self.source:current()) then callback(nil,'source_position_changed');return false end
    if not self:_retire_completed() then callback(nil,'upload_readback_unconfirmed');return false end
    local job={point=copy(point),intent=intent,scope=scope,started=self.now(),callback=callback};self.job=job
    job.poll=function()
        if self.job~=job then return end
        if not self:_current(job) then self:cancel();return end
        self.scheduler:scheduleIn(.1,job.poll)
    end
    self.scheduler:scheduleIn(.1,job.poll)
    self:_prepare_source(job)
    return true
end
function M:_send(job)
    job.stage,job.recovering='sending',nil
    local started,reason=self.service:start(job.metadata,function() return self:_current(job) end,function(result,token)
        if self.job~=job then return end
        if result.kind=='login' and result.authentication_expired==true and result.attempted==false
            and result.acknowledged==false and result.readbacks==0 and not token and self:_recover(job) then return end
        job.stage='delivering';local callback=job.completion;job.completion=nil
        local out=outcome(result,job.metadata)
        local delivered=pcall(callback,true,out.accepted,out)
        if delivered and out.accepted and token then self.service:accept(token) end
        self:_close(job)
    end)
    if not started then
        self:_close(job)
        return false,reason=='pending' and 'upload_readback_unconfirmed'
            or reason=='login' and 'source_native_authentication_unavailable' or 'source_position_changed'
    end
    return true
end
function M:_recover(job)
    local record,reason=self.service:pending()
    if job.recovery_attempted or record or reason or self.service.job or not self:_current(job) then return false end
    job.recovery_attempted,job.recovering=true,true
    if not self.recovery then self.recovery=require('weread.lib.native_source_recovery'):new{
        settings=self.settings,client=self.client,scheduler=self.scheduler,renewal=self.client._native_renewal} end
    local selected=job.access
    local started,handle=self.recovery:start(selected,function() return self:_current(job) end,function(fresh)
        if self.job~=job then return end
        job.renewal=nil
        if not fresh or not self:_current(job) then self:_fail(job,'source_native_authentication_unavailable');return end
        job.access,job.recovering=fresh,nil
        self:_prepare_source(job)
    end)
    if self.job==job then
        if started then job.renewal=handle else job.recovering=nil;return false end
    end
    return started==true
end
function M:_snapshot(job)
    local point,intent,candidate=job.point,job.intent,job.candidate
    local gate=self.make_gate();job.gate=gate
    self.worker=self.worker or self.source.make_worker()
    local input={candidate=copy(candidate),source=copy(point),expected_remote=copy(intent.expected_remote)}
    local client,settings,selected,snapshot=self.client,self.settings,job.access,self.snapshot
    local started=self.worker:start(function() return snapshot(client,settings,selected,input,gate) end,function(result)
        if self.job~=job then return end
        gate:close();job.gate=nil
        if not self:_current(job) then self:cancel();return end
        if type(result)=='table' and result.kind=='login' and result.authentication_expired==true and self:_recover(job) then return end
        local metadata=type(result)=='table' and result.metadata
        if type(result)~='table' or result.kind~='ready' or not C.valid(metadata)
            or metadata.file_id~=point.file_id or metadata.source_sha256~=point.raw_sha256
            or not P.equal(metadata.desired,candidate) or not Snapshot.matches_expected(metadata.before,intent.expected_remote) then
            local reason_=type(result)=='table' and result.kind=='login' and 'source_native_authentication_unavailable'
                or type(result)=='table' and result.kind=='changed' and 'source_remote_changed' or 'source_currentness_unavailable'
            self:_fail(job,reason_);return
        end
        if job.dispatched then job.metadata=copy(metadata);self:_send(job) else self:_plan(job,metadata) end
    end)
    if not started then self:_fail(job,'source_worker_unavailable') end
end
function M:_prepare_source(job)
    if not self:_current(job) then self:cancel();return end
    local point,intent=job.point,job.intent
    job.receipt=nil
    self.source:prepare_current_native_preview(function(candidate,reason,receipt)
        if self.job~=job then return end
        job.source_token=self.source.preview_token
        if not candidate or candidate.book_id~=point.book_id or candidate.chapter_uid~=point.chapter_uid
            or candidate.chapter_offset~=point.chapter_offset or candidate.raw_percent~=intent.percent
            or job.candidate and not Same(job.candidate,candidate) then self:_fail(job,reason or 'source_position_changed');return end
        job.receipt,job.candidate=receipt,copy(candidate)
        local deadline=self.source:native_preview_deadline(receipt,candidate)
        if not deadline then self:_fail(job,'source_position_changed');return end
        -- A new proof cannot extend a plan already offered to its caller.
        job.deadline=math.min(job.deadline or deadline,deadline)
        job.access=Access.capture(self.settings,self.credentials)
        if not job.access or job.access.renewal_pending then self:_fail(job,'source_native_authentication_unavailable');return end
        if not self:_current(job) then self:_fail(job,'source_position_changed');return end
        self:_snapshot(job)
    end)
    if self.job==job then job.source_token=self.source.preview_token end
end
return M
