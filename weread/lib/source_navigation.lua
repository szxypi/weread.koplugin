-- Local, source-bound navigation. The worker owns archive reads and raw-source
-- parsing; only the reader process may traverse its native DOM or navigate.
local Context = require('weread.lib.source_context')
local Dom = require('weread.lib.source_dom')
local Identity = require('weread.lib.book_file_identity')
local ReaderPosition = require('weread.lib.reader_position')
local Source = require('weread.lib.position_source')
local WorkerTask = require('weread.lib.source_position_worker')
local Navigation = {}
Navigation.__index = Navigation
local fields = {'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
local function copy_position(value)
    if type(value) ~= 'table' then return nil end
    local result = {}
    for _,key in ipairs(fields) do result[key]=value[key] end
    if type(value.chapter_title)=='string' and #value.chapter_title<=512 and not value.chapter_title:find('[%z%c]') then
        result.chapter_title=value.chapter_title
    end
    return result
end
local function valid_offset(position)
    return type(position)=='table' and Source.is_coordinate_basis(position.basis) and position.upload_verified==false
        and type(position.chapter_offset)=='number' and position.chapter_offset>=0
        and position.chapter_offset%1==0 and position.chapter_offset<=Source.MAX_BYTES*8
end
function Navigation:new(options)
    return setmetatable({scheduler=assert(options.scheduler),get_document=assert(options.get_document),
        get_book_id=assert(options.get_book_id),get_account=options.get_account or function() return '' end,
        get_mode=options.get_mode or function() return 'page' end,get_viewport_height=options.get_viewport_height,
        navigate=assert(options.navigate),on_applied=assert(options.on_applied),
        on_start=options.on_start,on_done=options.on_done,on_cancel=options.on_cancel,
        can_prepare=options.can_prepare or function() return true end,is_busy=options.is_busy or function() return false end,
        worker=options.worker,make_worker=options.make_worker or function()
            return require('weread.lib.memory_worker'):new{scheduler=options.scheduler,codec=options.codec}
        end,dom=options.dom or Dom,now=options.now or function()
            local time=require('ui/time');return time.to_s(time.monotonic())
        end,generation=0,sequence=0,state='idle'},self)
end
function Navigation:_owner(scope,allow_movement)
    if not scope or scope.generation~=self.generation or self.get_document()~=scope.document
        or tostring(self.get_book_id() or '')~=scope.position.book_id
        or tostring(self.get_account() or '')~=scope.account or scope.document.file~=scope.file then return false end
    local elapsed=self.now()-scope.started
    if elapsed<0 or elapsed>120 then return false end
    local identity=Identity.read_document(scope.document,scope.position.book_id)
    if identity.file_id~=scope.position.file_id then return false end
    local snapshot=Source.document_metadata(scope.document,scope.position.book_id,scope.position.chapter_uid,scope.position.render_path)
    if not snapshot or snapshot.metadata~=scope.metadata then return false end
    if not allow_movement and not Context.same_location(scope.location,Context.location(scope.document,self.get_mode())) then return false end
    return true
end
function Navigation:cancel()
    self.generation=self.generation+1
    local job=self.job
    self.job,self.committing=nil,false
    if job and job.task then self.scheduler:unschedule(job.task) end
    if self.worker then self.worker:cancel() end
    if job then
        job.thread,job.anchor,job.input=nil,nil,nil
        if self.on_done then pcall(self.on_done) end
        if self.on_cancel then pcall(self.on_cancel,job) end
    end
    self.state='idle'
end
function Navigation:on_view_changed()
    if self.job and not self.committing and not self:_owner(self.job.scope) then self:cancel() end
end
function Navigation:_finish(job,position,reason)
    if self.job~=job then return end
    if not self:_owner(job.scope,true) then self:cancel();return end
    self.job=nil
    job.thread,job.anchor,job.input=nil,nil,nil
    self.state=position and 'ready' or 'unavailable'
    if self.on_done then pcall(self.on_done) end
    if job.callback then pcall(job.callback,copy_position(position),reason) end
end
function Navigation:_schedule(job,delay,callback)
    if job.task then self.scheduler:unschedule(job.task) end
    local task
    task=function()
        if self.job~=job or job.task~=task then return end
        job.task=nil
        if not self:_owner(job.scope) then self:cancel();return end
        callback()
    end
    job.task=task
    self.scheduler:scheduleIn(math.max(0.1,delay),task)
end
function Navigation:_defer(job,callback)
    job.retries=(job.retries or 0)+1
    if job.retries>3 then self:_finish(job,nil,'resources_unavailable');return end
    self.state='deferred'
    self:_schedule(job,3,callback)
end
function Navigation:_apply(job,point)
    if not self:_owner(job.scope) or self.is_busy() then self:cancel();return end
    self.state,self.committing='applying',true
    local ok,applied=pcall(self.navigate,point.xpointer)
    self.committing=false
    if self.job~=job then return end
    if not self:_owner(job.scope,true) then self:cancel();return end
    local frame=ReaderPosition.snapshot(job.scope.document,self.get_mode(),self.get_viewport_height and self.get_viewport_height())
    if not ok or applied~=true or not ReaderPosition.contains_anchor(job.scope.document,frame,point.xpointer) then
        self:_finish(job,nil,'navigation_unavailable');return
    end
    local bound,accepted=pcall(self.on_applied,copy_position(job.position),point.xpointer,job.scope.metadata)
    if not bound or accepted~=true then self:_finish(job,nil,'target_changed');return end
    self:_finish(job,job.position)
end
function Navigation:_locate(job)
    if self.is_busy() or not self.can_prepare() then self:_defer(job,function() self:_locate(job) end);return end
    self.state='locating'
    job.thread=job.thread or coroutine.create(function()
        local first_yield,last_yield=true,self.now()
        local index,reason=self.dom.open_prepared(job.scope.document,job.scope.position.book_id,job.scope.metadata,{
            is_current=function() return self.job==job and self:_owner(job.scope) and not self.is_busy() end,
            -- DOM checks scope every 128 characters. Yield by elapsed CPU
            -- slice rather than sleeping 0.1s after each small character batch.
            yield=function()
                if first_yield or self.now()-last_yield>=0.02 then
                    first_yield=false
                    coroutine.yield()
                    last_yield=self.now()
                end
            end,
        })
        if not index then return nil,reason end
        return index:locate_anchor(job.anchor)
    end)
    local ok,point=coroutine.resume(job.thread)
    if not self:_owner(job.scope) then self:cancel();return end
    if not ok then self:_finish(job,nil,'target_unavailable');return end
    if coroutine.status(job.thread)~='dead' then
        self:_schedule(job,0.1,function() self:_locate(job) end);return
    end
    job.thread=nil
    if type(point)~='table' or point.co~=job.position.chapter_offset or point.file_id~=job.position.file_id
        or point.book_id~=job.position.book_id or point.chapter_uid~=job.position.chapter_uid
        or point.render_path~=job.position.render_path or type(point.xpointer)~='string' or #point.xpointer>4096 then
        self:_finish(job,nil,'target_unavailable');return
    end
    self:_apply(job,point)
end
function Navigation:_prepare(job)
    if self.is_busy() or not self.can_prepare() then self:_defer(job,function() self:_prepare(job) end);return end
    self.state='preparing'
    self.worker=self.worker or self.make_worker()
    local input=job.input
    local started=self.worker:start(function() return WorkerTask.prepare_target(input) end,function(result)
        if self.job~=job then return end
        if not self:_owner(job.scope) then self:cancel();return end
        local position=type(result)=='table' and result.position
        local anchor=type(result)=='table' and result.anchor
        local valid=valid_offset(position) and type(anchor)=='table' and result.request_id==input.request_id
        if valid then
            for _,key in ipairs(fields) do if position[key]~=job.scope.position[key] then valid=false end end
        end
        if not valid or type(anchor.text)~='string' or #anchor.text>8192 or anchor.co~=position.chapter_offset
            or anchor.basis~=position.basis or anchor.point_unit~='unicode_scalars'
            or type(anchor.point_offset)~='number' or anchor.point_offset<0 or anchor.point_offset%1~=0 or anchor.point_offset>8192 then
            self:_finish(job,nil,'target_unavailable');return
        end
        job.position=copy_position(position)
        job.anchor={text=anchor.text,co=anchor.co,point_offset=anchor.point_offset,point_unit=anchor.point_unit,basis=anchor.basis}
        job.input=nil
        self:_schedule(job,0.1,function() self:_locate(job) end)
    end)
    if not started and self.job==job then self:_finish(job,nil,'worker_unavailable') end
end
function Navigation:jump(position,callback)
    position=copy_position(position)
    if not valid_offset(position) then return false,'target_invalid' end
    local document=self.get_document()
    if not document or tostring(self.get_book_id() or '')~=position.book_id then return false,'target_changed' end
    local snapshot=Source.document_metadata(document,position.book_id,position.chapter_uid,position.render_path)
    local location=Context.location(document,self.get_mode())
    if not snapshot or not location then return false,'source_unavailable' end
    if position.basis~=Source.coordinate_basis(snapshot.record.format) then return false,'target_changed' end
    for _,key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path'}) do
        if position[key]~=snapshot.record[key] then return false,'target_changed' end
    end
    self:cancel()
    self.sequence=self.sequence+1
    local scope={document=document,file=document.file,position=position,metadata=snapshot.metadata,
        location=location,account=tostring(self.get_account() or ''),generation=self.generation,started=self.now()}
    local job={scope=scope,callback=callback,input={file=scope.file,book_id=position.book_id,chapter_uid=position.chapter_uid,
        render_path=position.render_path,identity=snapshot.identity,metadata=snapshot.metadata,target=position,request_id=self.sequence}}
    self.job=job
    if self.on_start then pcall(self.on_start) end
    self:_schedule(job,0.1,function() self:_prepare(job) end)
    return true
end
return Navigation
