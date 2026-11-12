-- Freeze only primitive source inputs while the document is alive. Archive
-- verification and freshness reads finish independently after it is closed.
local Source = require('weread.lib.position_source')
local Candidate = require('weread.lib.source_upload_candidate')
local Currentness = require('weread.lib.source_currentness')
local Readback = require('weread.lib.progress_readback')
local Task = require('weread.lib.source_position_worker')
local M = {}; M.__index = M
local active = {}
local fields = {'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key,item in pairs(value) do out[key] = copy(item) end; return out
end
local function same(a,b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for _i,key in ipairs(fields) do if a[key] ~= b[key] then return false end end
    return true
end
function M:new(options)
    local source = assert(options.source)
    local settings = assert(source.client and source.client.settings)
    return setmetatable({source=source,settings=settings,scheduler=assert(options.scheduler),
        namespace=options.namespace or settings.data_dir or settings,
        get_catalog=assert(options.get_catalog),now=options.now or os.time},self)
end
function M:_drop(entry,reason)
    if active[self.namespace] ~= entry then return end
    active[self.namespace] = nil
    self.scheduler:unschedule(entry.timeout)
    if entry.worker then entry.worker:cancel() end
    if entry.recovery and self.source.recovery then self.source.recovery:cancel(entry.recovery) end
    local callback = entry.callback; entry.callback = nil
    if entry.native then entry.native:cancel() end
    if callback then callback(nil,reason or 'source_cancelled') end
end
function M:cancel()
    local entry = active[self.namespace]
    if entry then entry.owner:_drop(entry) end
end
function M:on_reader_ready(book_id)
    local entry = active[self.namespace]
    if entry and entry.input.book_id == tostring(book_id) then entry.owner:_drop(entry,'source_position_changed') end
end
function M:freeze(intent)
    local point = type(intent) == 'table' and intent.source_position
    local source = self.source
    if type(point) ~= 'table' or not Source.is_coordinate_basis(point.basis) or point.upload_verified ~= false
        or point.book_id ~= intent.book_id or not same(point,source:current())
        or source.is_busy() or not source.can_prepare() then return nil end
    if point.basis=='raw_txt_utf16' and (intent.native_position_only~=true or type(intent.expected_remote)~='table') then return nil end
    local scope = source:_live()
    local context = source.get_upload_context and source.get_upload_context()
    local snapshot = scope and Source.document_metadata(source.get_document(),point.book_id,point.chapter_uid,point.render_path)
    local access = Currentness.capture(self.settings)
    if not scope or not source:_current(scope) or not snapshot or not context or not access or not access.web
        or context.book_id ~= point.book_id or context.percent ~= intent.percent then return nil end
    local expected = Currentness.expected{book_id=point.book_id,chapter_uid=point.chapter_uid,
        chapter_idx=Candidate.chapter_index(context.chapters,point.chapter_uid),
        raw_sha256=point.raw_sha256,raw_bytes=snapshot.record.raw_bytes}
    if not expected then return nil end
    self:cancel()
    local token = {}
    local entry = {owner=self,token=token,intent=copy(intent),access=access,expected=expected,frozen=self.now(),
        input={file=scope.file,book_id=point.book_id,chapter_uid=point.chapter_uid,identity=copy(snapshot.identity),
            metadata=snapshot.metadata,render_path=point.render_path,target=copy(point),
            chapters=copy(context.chapters),percent=context.percent,request_id=1}}
    if point.basis=='raw_txt_utf16' then
        entry.input.target={};for _i,key in ipairs(fields) do entry.input.target[key]=point[key] end
        entry.account_scope=self.settings.get_auth_scope and copy(self.settings:get_auth_scope())
    end
    active[self.namespace] = entry
    entry.timeout = function()
        if active[self.namespace] ~= entry then return end
        local deadline = entry.deadline or entry.frozen+60
        if self.now() < deadline then self.scheduler:scheduleIn(deadline-self.now(),entry.timeout); return end
        self:_drop(entry,'source_preparation_timeout')
    end
    self.scheduler:scheduleIn(60,entry.timeout)
    return token
end
function M:prepare(token,intent,callback)
    assert(type(callback) == 'function')
    local entry = active[self.namespace]
    if not entry or entry.owner ~= self or entry.token ~= token or entry.used
        or not Readback.same_intent(entry.intent,intent) or not Currentness.matches(self.settings,entry.access)
        or self.now()-entry.frozen < 0 or self.now()-entry.frozen > 60 then
        callback(nil,'source_position_changed'); return false
    end
    entry.used,entry.callback,entry.started = true,callback,self.now()
    entry.deadline=entry.started+35
    self.scheduler:unschedule(entry.timeout); self.scheduler:scheduleIn(35,entry.timeout)
    if entry.input.target.basis=='raw_txt_utf16' then return self:_launch_native(entry) end
    entry.worker = self.source.make_worker()
    return self:_launch(entry)
end
function M:_launch_native(entry)
    local face=require('weread.lib.native_close_source'):new{source=self.source,input=entry.input,expected=entry.expected,
        access=entry.access,account_scope=entry.account_scope,get_catalog=self.get_catalog,now=self.now,deadline=entry.deadline,
        is_current=function() return active[self.namespace]==entry and self.now()>=entry.frozen
            and (not entry.plan or entry.plan.detached==true) end}
    entry.face=face
    entry.native=require('weread.lib.native_source_upload'):new{source=face,scheduler=self.scheduler,now=self.now}
    return entry.native:prepare(copy(entry.intent),function(plan,reason)
        if active[self.namespace]~=entry or not entry.callback then if plan then plan.release() end;return end
        local callback=entry.callback;entry.callback=nil
        if not plan then self:_drop(entry);callback(nil,reason);return end
        local current,dispatch=plan.is_current,plan.dispatch
        plan.detached=true;entry.plan=plan
        plan.is_current=function() return active[self.namespace]==entry and plan.detached==true and current() end
        plan.release=function() self:_drop(entry) end
        plan.dispatch=function(done)
            if not plan.is_current() then return false,'source_position_changed' end
            return dispatch(function(...)
                local ok,value=pcall(done,...)
                self:_drop(entry)
                if not ok then error(value,0) end
            end)
        end
        callback(plan)
    end)
end
function M:_launch(entry)
    entry.sequence=(entry.sequence or 0)+1
    entry.started=self.now()
    -- These child inputs do not reference any inherited native document.
    local input,expected,access,client = copy(entry.input),copy(entry.expected),entry.access,self.source.client
    input.request_id=entry.sequence
    local started = entry.worker:start(function()
        local result = Task.prepare_upload(input)
        if result.candidate then
            local proof=Currentness.run(client,expected,access);result.check,result.error=proof.check,proof.error
        end
        return result
    end,function(result)
        if active[self.namespace] ~= entry or entry.sequence~=input.request_id or not entry.callback then return end
        local candidate = type(result) == 'table' and result.candidate
        local projected = type(candidate) == 'table' and Candidate.project(input.target,candidate.summary,
            self.get_catalog(input.book_id),input.percent)
        local function valid(allow_transition)
            local age = self.now()-entry.started
            return active[self.namespace] == entry and age >= 0 and age <= 30 and self.now()<=entry.deadline
                and (allow_transition or Currentness.matches(self.settings,entry.access))
                and Candidate.same(Candidate.project(input.target,candidate.summary,
                    self.get_catalog(input.book_id),input.percent),candidate)
        end
        if type(result) ~= 'table' or result.request_id ~= input.request_id or not same(result.position,input.target)
            or not Candidate.same(projected,candidate) or not valid() then
            self:_drop(entry,'source_currentness_unavailable'); return
        end
        if result.error=='source_web_expired' and not result.check then
            if entry.recovery_attempted or not self.source.recovery then self:_drop(entry,'source_authentication_unavailable');return end
            entry.recovery_attempted=true
            local renewing,handle=self.source.recovery:start(input.book_id,access,function() return valid(true) end,function(fresh,why)
                if active[self.namespace]~=entry or entry.sequence~=input.request_id then return end
                if fresh then entry.access=fresh;self:_launch(entry) else self:_drop(entry,why) end
            end)
            if active[self.namespace]==entry and entry.sequence==input.request_id then
                if renewing then entry.recovery=handle else self:_drop(entry,'source_authentication_unavailable') end
            end
            return
        end
        if not Currentness.packet(result.check,expected) then self:_drop(entry,'source_currentness_unavailable');return end
        local wire = {}; for _i,key in ipairs({'book_id','chapter_uid','chapter_idx','chapter_offset','percent','summary'}) do wire[key] = candidate[key] end
        local original,origin,deadline = copy(wire),copy(input.target),math.min(entry.started+30,entry.deadline)
        local plan
        plan = {position=wire,source_position=copy(origin),basis='filtered_xhtml_utf16',deadline=deadline,detached=true,
            is_current=function()
                return valid() and Candidate.same(plan.position,original) and same(plan.source_position,origin)
                    and plan.deadline == deadline and plan.detached == true and plan.basis == 'filtered_xhtml_utf16'
            end,
            release=function() self:_drop(entry) end}
        local callback=entry.callback
        entry.callback=nil
        callback(plan)
    end)
    if not started and active[self.namespace] == entry then self:_drop(entry,'source_worker_unavailable') end
    return started == true
end
return M
