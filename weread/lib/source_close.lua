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
    local callback = entry.callback; entry.callback = nil
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
    if type(point) ~= 'table' or point.basis ~= 'filtered_xhtml_utf16' or point.upload_verified ~= false
        or point.book_id ~= intent.book_id or not same(point,source:current())
        or source.is_busy() or not source.can_prepare() then return nil end
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
    active[self.namespace] = entry
    entry.timeout = function()
        if active[self.namespace] ~= entry then return end
        local deadline = entry.started and entry.started+35 or entry.frozen+60
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
    self.scheduler:unschedule(entry.timeout); self.scheduler:scheduleIn(35,entry.timeout)
    entry.worker = self.source.make_worker()
    -- These child inputs do not reference any inherited native document.
    local input,expected,access,client = copy(entry.input),copy(entry.expected),entry.access,self.source.client
    local started = entry.worker:start(function()
        local result = Task.prepare_upload(input)
        if result.candidate then result.check = Currentness.fetch(client,expected,access) end
        return result
    end,function(result)
        if active[self.namespace] ~= entry then return end
        local candidate = type(result) == 'table' and result.candidate
        local projected = type(candidate) == 'table' and Candidate.project(input.target,candidate.summary,
            self.get_catalog(input.book_id),input.percent)
        local function valid()
            local age = self.now()-entry.started
            return active[self.namespace] == entry and age >= 0 and age <= 30
                and Currentness.matches(self.settings,entry.access)
                and Candidate.same(Candidate.project(input.target,candidate.summary,
                    self.get_catalog(input.book_id),input.percent),candidate)
        end
        if type(result) ~= 'table' or result.request_id ~= input.request_id or not same(result.position,input.target)
            or not Candidate.same(projected,candidate) or not Currentness.packet(result.check,expected) or not valid() then
            self:_drop(entry,'source_currentness_unavailable'); return
        end
        local wire = {}; for _i,key in ipairs({'book_id','chapter_uid','chapter_idx','chapter_offset','percent','summary'}) do wire[key] = candidate[key] end
        local original,origin,deadline = copy(wire),copy(input.target),entry.started+30
        local plan
        plan = {position=wire,source_position=copy(origin),basis='filtered_xhtml_utf16',deadline=deadline,detached=true,
            is_current=function()
                return valid() and Candidate.same(plan.position,original) and same(plan.source_position,origin)
                    and plan.deadline == deadline and plan.detached == true and plan.basis == 'filtered_xhtml_utf16'
            end,
            release=function() self:_drop(entry) end}
        entry.callback = nil
        callback(plan)
    end)
    if not started and active[self.namespace] == entry then self:_drop(entry,'source_worker_unavailable') end
    return started == true
end
return M
