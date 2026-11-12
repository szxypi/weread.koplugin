-- A current native source point becomes wire coordinates only at dispatch.
-- Opaque plans and text stay in memory; checkpoints retain their local units.
local Source=require('weread.lib.position_source')
local Candidate=require('weread.lib.source_upload_candidate')
local M={};M.__index=M
local fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
local function failure(reason)
    if reason=='offline' then return reason end
    if reason=='no_visible_text' then return 'source_no_visible_text' end
    if reason=='source_unavailable' or reason=='source_changed' then return 'source_data_unavailable' end
    return type(reason)=='string' and reason:match('^source_') and reason or 'source_position_unavailable'
end
local function same(first,second)
    if type(first)~='table' or type(second)~='table' then return false end
    for _i,key in ipairs(fields) do if first[key]~=second[key] then return false end end
    return true
end
function M:new(options)
    return setmetatable({source=assert(options.source),scheduler=assert(options.scheduler),now=options.now or os.time},self)
end
function M:_native()
    if not self.native then
        self.native=require('weread.lib.native_source_upload'):new{source=self.source,scheduler=self.scheduler,now=self.now}
    end
    return self.native
end
function M:_finish(job,plan,reason)
    if self.job~=job then return end
    self.job=nil;self.scheduler:unschedule(job.timeout)
    job.callback(plan,reason)
end
function M:on_view_changed()
    if self.native then self.native:on_view_changed() end
    local job=self.job
    if not job then return end
    if job.scope and not self.source:_current(job.scope) or job.point and not same(job.point,self.source:current()) then
        self.source:cancel_upload_preview();self:_finish(job,nil,'source_position_changed')
    end
end
function M:cancel()
    local native=self.native and self.native:cancel()
    if not self.job then return native==true end
    self.source:cancel_upload_preview();self:_finish(self.job,nil,'source_cancelled');return true
end
function M:prepare(intent,callback)
    assert(type(callback)=='function')
    if type(intent)=='table' and type(intent.source_position)=='table' and intent.source_position.basis=='raw_txt_utf16'
        and intent.native_position_only~=true then callback(nil,'source_format_unsupported');return false end
    if self.native and self.native.job and (type(intent)~='table' or intent.native_position_only~=true) then
        callback(nil,'source_busy');return false
    end
    if self.native then self.native:cancel() end
    if self.job then
        self.source:cancel_upload_preview()
        self:_finish(self.job,nil,'source_cancelled')
    end
    if type(intent)~='table' then callback(nil,'source_position_unavailable');return false end
    if type(intent.book_id)=='string' and intent.book_id:sub(1,3)=='CB_' then
        callback(nil,'source_book_sync_unsupported');return false
    end
    local point=intent.source_position
    if intent.native_position_only==true and type(point)=='table' and point.basis=='raw_txt_utf16' then
        return self:_native():prepare(intent,callback)
    end
    if type(point)=='table' and point.basis~='filtered_xhtml_utf16' then callback(nil,'source_format_unsupported');return false end
    local provided=point~=nil
    local scope=not provided and self.source:_live()
    if (provided and (type(point)~='table' or point.basis~='filtered_xhtml_utf16'
        or point.upload_verified~=false or point.book_id~=intent.book_id or not same(point,self.source:current())))
        or not provided and (not scope or scope.book_id~=intent.book_id) then
        callback(nil,'source_position_unavailable');return false
    end
    local job={callback=callback,deadline=self.now()+35,scope=scope};self.job=job
    job.timeout=function()
        if self.job~=job then return end
        if self.now()<job.deadline then self.scheduler:scheduleIn(job.deadline-self.now(),job.timeout);return end
        self.source:cancel_upload_preview();self:_finish(job,nil,'source_preparation_timeout')
    end
    self.scheduler:scheduleIn(35,job.timeout)
    local function prepare_point(captured,why)
        if self.job~=job then return end
        if captured and captured.basis=='raw_txt_utf16' and intent.native_position_only==true
            and captured.book_id==intent.book_id and (not scope or self.source:_current(scope)) then
            self.job=nil;self.scheduler:unschedule(job.timeout)
            local native_intent={};for key,value in pairs(intent) do native_intent[key]=value end
            native_intent.source_position=captured
            self:_native():prepare(native_intent,callback);return
        end
        if captured and captured.basis~='filtered_xhtml_utf16' then self:_finish(job,nil,'source_format_unsupported');return end
        if not captured or captured.upload_verified~=false
            or captured.book_id~=intent.book_id or scope and not self.source:_current(scope) then
            self:_finish(job,nil,failure(why));return
        end
        local pinned={};for _i,key in ipairs(fields) do pinned[key]=captured[key] end
        job.point=pinned
        self.source:prepare_current_upload_preview(function(candidate,reason,receipt)
            if self.job~=job then return end
            if type(candidate)~='table' or candidate.book_id~=pinned.book_id or candidate.chapter_uid~=pinned.chapter_uid
                or candidate.chapter_offset~=pinned.chapter_offset or candidate.basis~='filtered_xhtml_utf16' or candidate.upload_verified~=false then
                self:_finish(job,nil,failure(reason));return
            end
            local plan,expected_wire,deadline
            local function current()
                if plan and (not Candidate.same(plan.position,expected_wire) or not same(plan.source_position,pinned)
                    or plan.deadline~=deadline) then return false end
                return same(pinned,self.source:current()) and self.source:is_current_upload_preview(receipt,candidate)
            end
            deadline=self.source:upload_preview_deadline(receipt,candidate)
            if candidate.percent~=intent.percent or not current() or not deadline then
                self:_finish(job,nil,'source_position_changed');return
            end
            local wire={}
            for _i,key in ipairs({'book_id','chapter_uid','chapter_idx','chapter_offset','percent','summary'}) do wire[key]=candidate[key] end
            expected_wire={};for key,value in pairs(wire) do expected_wire[key]=value end
            local origin={};for _i,key in ipairs(fields) do origin[key]=pinned[key] end
            plan={position=wire,is_current=current,deadline=deadline,basis=Source.coordinate_basis('web_xhtml'),source_position=origin}
            self:_finish(job,plan)
        end)
    end
    if provided then prepare_point(point)
    else
        self.source:check(prepare_point)
        scope.generation=self.source.generation
    end
    return true
end
return M
