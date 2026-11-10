-- Live local position preparation. Reader-owned native calls are cooperative;
-- source parsing/hashing runs in a separate process with an independent ZIP FD.
local Context = require('weread.lib.source_context')
local Identity = require('weread.lib.book_file_identity')
local Source = require('weread.lib.position_source')
local WorkerTask = require('weread.lib.source_position_worker')
local Candidate = require('weread.lib.source_upload_candidate')
local Currentness = require('weread.lib.source_currentness')
local Service = {}
Service.__index = Service
local function clone(value)
    if type(value)~='table' then return value end
    local result={}
    for key,item in pairs(value) do result[key]=clone(item) end
    return result
end
function Service:new(options)
    return setmetatable({ scheduler=assert(options.scheduler), get_document=assert(options.get_document),
        get_book_id=assert(options.get_book_id), get_account=options.get_account or function() return '' end,
        get_mode=options.get_mode or function() return 'page' end, context=options.context or Context,
        worker=options.worker, make_worker=options.make_worker or function()
            return require('weread.lib.memory_worker'):new{scheduler=options.scheduler,codec=options.codec}
        end, can_prepare=options.can_prepare or function() return true end,
        is_busy=options.is_busy or function() return false end, on_change=options.on_change,
        get_retained=options.get_retained,
        get_upload_context=options.get_upload_context,
        client=options.client, is_online=options.is_online or function() return false end,
        get_viewport_height=options.get_viewport_height,
        now=options.now or os.time, generation=0, sequence=0, state='idle', pauses={} },self)
end
function Service:_notify()
    if self.on_change then pcall(self.on_change,self.state,clone(self.result)) end
end
function Service:_held()
    if not self.get_retained or next(self.pauses) or self.state=='idle' then return nil end
    local ok,position=pcall(self.get_retained)
    return ok and type(position)=='table' and clone(position) or nil
end
-- ReaderRolling can change its logical marker without emitting a movement
-- event for a same-line jump. Recheck once after dispatch, or when a caller
-- observes an expired held target. This never parses source on the UI thread.
function Service:_verify_held_later()
    if self.task or self.job then return end
    local generation=self.generation
    local task
    task=function()
        if self.task~=task then return end
        self.task=nil
        if self.generation==generation and not self:_held() then self:on_view_changed(true) end
    end
    self.task=task
    self.scheduler:scheduleIn(0.1,task)
end
function Service:_set(state,reason)
    self.state,self.reason=state,reason
    self:_notify()
end
function Service:_invalidate(state)
    self.generation=self.generation+1
    if self.task then self.scheduler:unschedule(self.task); self.task=nil end
    if self.worker then self.worker:cancel() end
    self:cancel_upload_preview()
    self.job,self.scope,self.result=nil,nil,nil
    self:_set(state or 'idle')
end
function Service:cancel_upload_preview()
    self.preview_job,self.preview_token=nil,nil
    self.checked_previews=setmetatable({},{__mode='k'})
    if self.preview_worker then self.preview_worker:cancel() end
end

local point_fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
function Service:_preview_current(job,candidate)
    if not self:_current(job.scope) or self.is_busy() or not self.can_prepare() then return false end
    local point=self:current()
    for _i,key in ipairs(point_fields) do if not point or point[key]~=job.point[key] then return false end end
    local live=self.get_upload_context and self.get_upload_context()
    return live and live.book_id==point.book_id
        and Candidate.same(Candidate.project(point,candidate.summary,live.chapters,live.percent),candidate) or false
end

-- Explicit, read-only freshness preparation. The opaque receipt stays in
-- memory, expires after 30 seconds and never enables the upload adapter.
function Service:prepare_current_upload_preview(callback)
    assert(type(callback)=='function')
    if not self.is_online() then self:cancel_upload_preview();callback(nil,'offline');return false end
    if not self.client then self:cancel_upload_preview();callback(nil,'web_required');return false end
    return self:prepare_upload_preview(function(candidate,reason)
        if not candidate then callback(nil,reason);return end
        if not self.is_online() then callback(nil,'offline');return end
        local selected=Currentness.capture(self.client.settings)
        if not selected or not selected.web then callback(nil,'web_required');return end
        local point=self:current()
        local scope=self:_live()
        local snapshot=point and Source.document_metadata(self.get_document(),point.book_id,point.chapter_uid,point.render_path)
        if not point or not scope or not snapshot then callback(nil,'context_unavailable');return end
        scope.metadata,scope.render_path=snapshot.metadata,point.render_path
        local expected=Currentness.expected{book_id=point.book_id,chapter_uid=point.chapter_uid,chapter_idx=candidate.chapter_idx,
            raw_sha256=point.raw_sha256,raw_bytes=snapshot.record.raw_bytes}
        if not expected then callback(nil,'context_unavailable');return end
        self.sequence=self.sequence+1
        local job={scope=scope,point=clone(point),candidate=clone(candidate),access=selected,expected=expected,
            started=self.now(),request_id=self.sequence}
        local token=self.preview_token
        self.preview_job=job
        local started=self.preview_worker:start(function()
            return {request_id=job.request_id,check=Currentness.fetch(self.client,expected,selected)}
        end,function(result)
            if self.preview_job~=job or self.preview_token~=token then return end
            self.preview_job=nil
            if not self:_preview_current(job,candidate) or not self.is_online()
                or not Currentness.matches(self.client.settings,selected) then return end
            local age=self.now()-job.started
            if type(result)~='table' or result.request_id~=job.request_id
                or not Currentness.packet(result.check,expected) or age<0 or age>30 then
                callback(nil,'source_currentness_unavailable');return
            end
            local receipt={}
            self.checked_previews[receipt]=job
            callback(clone(candidate),nil,receipt)
        end)
        if not started and self.preview_job==job then self.preview_job=nil;callback(nil,'worker_unavailable') end
    end)
end
function Service:is_current_upload_preview(receipt,candidate)
    local job=type(receipt)=='table' and self.checked_previews and self.checked_previews[receipt]
    if not job or not self.client or not self.is_online() or not Candidate.same(job.candidate,candidate) then return false end
    local age=self.now()-job.started
    return age>=0 and age<=30 and Currentness.matches(self.client.settings,job.access) and self:_preview_current(job,candidate) or false
end
function Service:upload_preview_deadline(receipt,candidate)
    if not self:is_current_upload_preview(receipt,candidate) then return nil end
    return self.checked_previews[receipt].started+30
end

-- No network or persistence. The caller receives an immutable, unverified
-- candidate only while the original native point and catalog still match.
function Service:prepare_upload_preview(callback)
    assert(type(callback)=='function')
    self:cancel_upload_preview()
    if not self.get_upload_context then callback(nil,'context_unavailable');return false end
    local token={};self.preview_token=token
    return self:check(function(point,reason)
        if self.preview_token~=token then return end
        if not point then callback(nil,reason);return end
        if point.basis~='filtered_xhtml_utf16' then callback(nil,'source_unsupported');return end
        if self.is_busy() or not self.can_prepare() then callback(nil,'resources_unavailable');return end
        local context=self.get_upload_context()
        local snapshot=Source.document_metadata(self.get_document(),point.book_id,point.chapter_uid,point.render_path)
        local scope=self:_live()
        if not context or context.book_id~=point.book_id or not snapshot or not scope then callback(nil,'context_unavailable');return end
        scope.metadata,scope.render_path=snapshot.metadata,point.render_path
        local input={file=scope.file,book_id=point.book_id,chapter_uid=point.chapter_uid,identity=snapshot.identity,
            metadata=snapshot.metadata,render_path=point.render_path,target=clone(point),
            chapters=clone(context.chapters),percent=context.percent}
        self.sequence=self.sequence+1;input.request_id=self.sequence
        local job={scope=scope,point=clone(point),request_id=input.request_id}
        self.preview_job=job
        self.preview_worker=self.preview_worker or self.make_worker()
        local started=self.preview_worker:start(function() return WorkerTask.prepare_upload(input) end,function(result)
            if self.preview_job~=job or self.preview_token~=token then return end
            self.preview_job=nil
            if not self:_current(scope) or self.is_busy() then return end
            local current=self:current()
            for _i,key in ipairs({'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}) do
                if not current or current[key]~=job.point[key] then return end
            end
            local live=self.get_upload_context()
            local candidate=type(result)=='table' and result.candidate
            local expected=live and live.book_id==point.book_id and type(candidate)=='table'
                and Candidate.project(current,candidate.summary,live.chapters,live.percent)
            if type(result)=='table' and result.request_id==job.request_id and Candidate.same(expected,candidate) then
                callback(clone(candidate))
            else callback(nil,'candidate_unavailable') end
        end)
        if not started and self.preview_job==job then self.preview_job=nil;callback(nil,'worker_unavailable') end
    end)
end
function Service:stop() self:_invalidate('idle') end
function Service:pause(reason)
    self.pauses[reason or 'reader']=true
    self:_invalidate('paused')
end
function Service:resume(reason)
    self.pauses[reason or 'reader']=nil
    if not next(self.pauses) then self:on_view_changed(true) end
end
function Service:on_reader_ready()
    self.pauses={}
    self:_invalidate('waiting')
    self:on_view_changed(true)
end
function Service:on_account_changed()
    self:_invalidate(next(self.pauses) and 'paused' or 'waiting')
    if not next(self.pauses) then self:on_view_changed(true) end
end
function Service:_live()
    local document=self.get_document()
    local book_id=self.get_book_id()
    if not document or not book_id or tostring(book_id):sub(1,7)=='MP_WXS_' then return nil end
    book_id=tostring(book_id)
    local location=self.context.location(document,self.get_mode())
    if not location then return nil end
    local identity=Identity.read_document(document,book_id)
    if type(identity.file_id)~='string' or #identity.file_id~=64 or identity.book_id~=book_id then return nil end
    return {document=document,file=document.file,book_id=book_id,location=location,identity=identity,
        account=tostring(self.get_account() or ''),generation=self.generation}
end
function Service:_current(scope)
    if not scope or scope.generation~=self.generation or next(self.pauses) then return false end
    local live=self:_live()
    if not live or live.document~=scope.document or live.file~=scope.file or live.account~=scope.account or live.book_id~=scope.book_id
        or live.identity.file_id~=scope.identity.file_id or not Context.same_location(live.location,scope.location) then return false end
    if scope.metadata then
        local current=Source.document_metadata(scope.document,scope.book_id,nil,scope.render_path)
        if not current or current.metadata~=scope.metadata then return false end
    end
    return true
end
function Service:_schedule(job,delay,callback)
    if self.task then self.scheduler:unschedule(self.task) end
    local task
    task=function()
        if self.task~=task then return end
        self.task=nil
        if self.job~=job then return end
        if not self:_current(job.scope) then self:on_view_changed(true); return end
        callback()
    end
    self.task=task
    self.scheduler:scheduleIn(math.max(0.1,delay or 0.1),task)
end
function Service:_finish(job,value,reason)
    if self.job~=job then return end
    if not self:_current(job.scope) then self:on_view_changed(true); return end
    self.job=nil
    job.thread,job.input=nil,nil
    self.scope=job.scope
    self.result=value and clone(value) or nil
    if self.result then self.result.captured_at=job.started end
    self:_set(value and 'ready' or 'unavailable',reason)
    if job.callback and self:_current(job.scope) and not self.is_busy() then
        pcall(job.callback,clone(self.result),reason)
    end
end
function Service:_defer(job)
    job.retries=(job.retries or 0)+1
    if job.retries>3 then self:_finish(job,nil,'resources_unavailable'); return end
    job.thread,job.input=nil,nil
    self:_set('deferred','resources_unavailable')
    self:_schedule(job,3,function() self:_capture(job) end)
end
function Service:_launch(job)
    if not self:_current(job.scope) then self:on_view_changed(true); return end
    if not self.can_prepare() then self:_defer(job); return end
    local input=job.input
    self.worker=self.worker or self.make_worker()
    self:_set('preparing')
    local started=self.worker:start(function() return WorkerTask.capture(input) end,function(result)
        if self.job~=job then return end
        if not self:_current(job.scope) then self:on_view_changed(true); return end
        local position=type(result)=='table' and result.position
        local record=Source.decode_metadata(input.metadata)
        if type(position)~='table' or result.request_id~=input.request_id or not record or position.book_id~=job.scope.book_id
            or position.file_id~=job.scope.identity.file_id or position.chapter_uid~=record.chapter_uid
            or position.raw_sha256~=record.raw_sha256 or position.render_path~=record.render_path
            or position.book_version~=record.book_version or position.basis~=Source.coordinate_basis(record.format)
            or position.upload_verified~=false or type(position.chapter_offset)~='number'
            or position.chapter_offset<0 or position.chapter_offset>Source.MAX_BYTES*8 or position.chapter_offset%1~=0 then
            self:_finish(job,nil,type(result)=='table' and result.error or 'position_unavailable')
            return
        end
        local accepted={}
        for _i,key in ipairs({'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256',
            'render_path','basis','upload_verified'}) do accepted[key]=position[key] end
        if type(position.chapter_title)=='string' and #position.chapter_title<=512 and not position.chapter_title:find('[%z%c]') then
            accepted.chapter_title=position.chapter_title
        end
        self:_finish(job,accepted)
    end)
    if not started and self.job==job then self:_finish(job,nil,'worker_unavailable') end
end
function Service:_capture(job)
    if self.is_busy() or not self.can_prepare() then self:_defer(job); return end
    self:_set('preparing')
    job.thread=job.thread or coroutine.create(function()
        return self.context.capture(job.scope.document,job.scope.book_id,job.scope.location,{
            viewport_height=self.get_viewport_height and self.get_viewport_height(),
            is_current=function() return self.job==job and self:_current(job.scope) and not self.is_busy() end,
            yield=function() coroutine.yield() end,
        })
    end)
    local ok,input=coroutine.resume(job.thread)
    if not self:_current(job.scope) then self:on_view_changed(true); return end
    if not ok then self:_finish(job,nil,'context_unavailable'); return end
    if coroutine.status(job.thread)~='dead' then
        self:_schedule(job,0.1,function() self:_capture(job) end)
        return
    end
    if not input or input.error then
        if input and input.error=='cancelled' and self.is_busy() then self:_defer(job)
        else self:_finish(job,nil,input and input.error or 'context_unavailable') end
        return
    end
    job.scope.metadata,job.scope.render_path=input.metadata,input.render_path
    self.sequence=self.sequence+1
    input.request_id=self.sequence
    job.input,job.thread=input,nil
    self:_launch(job)
end
function Service:on_view_changed(force)
    if next(self.pauses) then return false end
    local live=self:_live()
    if not live then self:_invalidate('unsupported'); return false end
    local held=self:_held()
    if held then
        self:cancel_upload_preview()
        if self.job or self.task then self:_invalidate('waiting');live.generation=self.generation end
        self.scope,self.result=live,held
        self:_set('ready')
        self:_verify_held_later()
        return true
    end
    local previous=self.job and self.job.scope or self.scope
    if not force and previous and self:_current(previous) and not (self.result and self.result.retained_source_target) then return true end
    self:_invalidate('waiting')
    live.generation=self.generation
    local job={scope=live,started=self.now()}
    self.job=job
    self:_schedule(job,0.3,function() self:_capture(job) end)
    return true
end
function Service:current()
    local held=self:_held()
    if held then return held,'ready' end
    if self.result and self.result.retained_source_target then
        if not next(self.pauses) and self.state~='idle' then self:_verify_held_later() end
        return nil,'stale','position_unavailable'
    end
    if self.result then
        if self:_current(self.scope) then return clone(self.result),self.state end
        return nil,'stale','position_unavailable'
    end
    return nil,self.state,self.reason
end
function Service:check(callback)
    if next(self.pauses) then callback(nil,'paused'); return false end
    local position=self:current()
    if position then callback(position); return true end
    if not self.job and not self:on_view_changed(true) then callback(nil,'source_unavailable'); return false end
    if self.job then self.job.callback=callback; return true end
    callback(nil,'position_unavailable')
    return false
end
return Service
