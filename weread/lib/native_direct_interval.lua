-- Timed native chapter sync is scoped to one explicitly verified reader
-- session. It never wakes the network or retries an uncertain write.
local UI=require('ui/uimanager')
local Context=require('weread.lib.source_context')
local Identity=require('weread.lib.book_file_identity')
local Access=require('weread.lib.native_read_access')
local Currentness=require('weread.lib.source_currentness')
local Contract=require('weread.lib.native_position_contract')
local P=require('weread.lib.native_position_protocol')
local State=require('weread.lib.native_cloud_state')
local Minutes=require('weread.lib.progress_interval').minutes
local _=require('weread.lib.plugin_util').tr
local M={};M.__index=M
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
function M:new(host,options)
    options=options or {}
    return setmetatable({host=host,scheduler=options.scheduler or UI,now=options.now or os.time,
        start=options.start or function(h,e,o) return require('weread.ui.native_direct_position').start(h,e,o) end},self)
end
function M:current()
    local c=self.context;local h=self.host
    return c and h._native_direct_interval==self and not h._weread_suspended and h.ui==c.reader
        and c.reader.document==c.document and c.document.file==c.file and (h._reader_session_gen or 0)==c.session
        and h.settings:auth_scope_matches(c.scope) and h.library_db and h.library_db:accountKey()==c.account
end
function M:access_current()
    local c=self.context
    return self:current() and Access.matches(self.host.settings,c.native) and Currentness.matches(self.host.settings,c.web)
end
function M:minutes()
    local settings=self.host.settings
    if type(settings.get)~='function' then return 0 end
    local config=settings:get('sync',{})
    return Minutes(type(config)=='table' and config.upload_interval_minutes)
end
function M:unschedule()
    if self.task then self.scheduler:unschedule(self.task);self.task=nil end
    self.started,self.due,self.interval=nil,nil,nil
end
function M:stop()
    self:unschedule();local running=self.attempt;self.context,self.attempt=nil,nil
    if self.host._native_direct_interval==self then self.host._native_direct_interval=nil end
    local ctx=self.host._native_direct_position
    if running and ctx and ctx.automatic then require('weread.ui.native_direct_position').cancel(self.host) end
end
function M:arm(entry,ctx,metadata,which)
    if type(entry)~='table' or type(ctx)~='table' or not Contract.valid(metadata)
        or metadata.basis~='filtered_xhtml_utf16' or metadata.book_id~=entry.book_id
        or metadata.file_id~=entry.file_id or metadata.source_sha256~=entry.source_sha256
        or metadata.version~=entry.book_version or which~='before' and which~='desired'
        or type(ctx.location)~='table' or type(ctx.scope)~='table' or not ctx.reader or not ctx.document
        or not State.valid(metadata[which]) or type(self.host.settings.get)~='function' then return false end
    local old=self.host._native_direct_interval;if old and old~=self then old:stop() end
    self:unschedule();self.dirty,self.attempt=false,nil
    self.context={entry=copy(entry),reader=ctx.reader,document=ctx.document,file=ctx.file,scope=ctx.scope,
        session=ctx.session,account=ctx.account,native=ctx.native,web=ctx.web,location=copy(ctx.location),
        baseline={position=copy(metadata[which]),counts=copy(metadata.counts),version=metadata.version,
            shelf_sha256=metadata.shelf_sha256,source_sha256=metadata.source_sha256,file_id=metadata.file_id}}
    self.host._native_direct_interval=self
    if not self:current() then self:stop();return false end
    return true
end
function M:changed()
    local c=self.context
    if not self:current() then self:stop();return end
    local location=Context.location(c.document,c.reader.view and c.reader.view.view_mode or 'page')
    if not location then self:stop();return end
    self.dirty=not Context.same_location(c.location,location)
    self:refresh()
end
function M:finish(attempt,status,metadata,location)
    if self.attempt~=attempt then return end
    self.attempt=nil
    if not self:current() then self:stop();return end
    if status=='confirmed' or status=='same' then
        local b=self.context.baseline
        if not Contract.valid(metadata) or not State.valid(metadata[status=='same' and 'before' or 'desired'])
            or not State.equal(metadata.before,b.position) or not P.same_counts(metadata.counts,b.counts)
            or metadata.version~=b.version or metadata.shelf_sha256~=b.shelf_sha256
            or metadata.source_sha256~=b.source_sha256 or metadata.file_id~=b.file_id
            or type(location)~='table' then self:stop();return end
        local selected=status=='same' and metadata.before or metadata.desired
        self.context.baseline={position=copy(selected),counts=copy(metadata.counts),version=metadata.version,
            shelf_sha256=metadata.shelf_sha256,source_sha256=metadata.source_sha256,file_id=metadata.file_id}
        self.context.location=copy(location);self:changed();return
    end
    if status=='cancelled' then self:changed();return end
    self:stop()
    if self.host.showTransientInfo then
        self.host:showTransientInfo(_(status=='conflict' and 'Automatic position sync paused because cloud reading state changed.'
            or status=='unconfirmed' and 'Automatic position sync needs review. Open sync to check it.'
            or 'Automatic position sync paused. Sync this page again to resume.'),2)
    end
end
function M:refresh()
    if not self:current() then self:stop();return false end
    local minutes=self:minutes()
    if minutes==0 or not self.dirty then self:unschedule();return false end
    if self.interval and self.interval~=minutes then self:unschedule() end
    if self.task or self.attempt then return true end
    local now=self.now();self.started,self.due,self.interval=now,now+minutes*60,minutes
    local task
    task=function()
        if self.task~=task then return end
        if not self:current() then self:stop();return end
        if self:minutes()~=minutes then self:unschedule();self:refresh();return end
        local current=self.now()
        if current<self.started then self:unschedule();self:refresh();return end
        if current<self.due then self.scheduler:scheduleIn(self.due-current,task);return end
        self.task,self.started,self.due,self.interval=nil,nil,nil,nil
        if not self.dirty or not self:access_current() then self:stop();return end
        local h,c=self.host,self.context
        local online=h.isNetworkConnected and h:isNetworkConnected() or not h.isNetworkConnected and h.isNetworkOnline and h:isNetworkOnline()
        if not online then self:stop();return end
        if h._native_direct_position or h.busy_message then self:refresh();return end
        local identity=Identity.read_document(c.document,c.entry.book_id)
        if identity.file_id~=c.entry.file_id or identity.book_id~=c.entry.book_id
            or identity.book_version~=c.entry.book_version then self:stop();return end
        local attempt={};self.attempt=attempt
        local options={upload=true,automatic={baseline=copy(c.baseline),
            current=function() return self.attempt==attempt and self:current() and self:minutes()==minutes end,
            done=function(status,metadata,location) self:finish(attempt,status,metadata,location) end}}
        local ok,started=pcall(self.start,h,c.entry,options)
        if self.attempt==attempt and (not ok or not started) then self.attempt=nil;self:stop() end
    end
    self.task=task;self.scheduler:scheduleIn(minutes*60,task);return true
end
function M:settings_changed()
    self:unschedule()
    local ctx=self.host._native_direct_position
    if self.attempt and ctx and ctx.automatic then require('weread.ui.native_direct_position').cancel(self.host) end
    self:refresh()
end
function M.arm_session(host,entry,ctx,metadata,which)
    return M:new(host):arm(entry,ctx,metadata,which)
end
function M.on_view_changed(host)
    local value=host._native_direct_interval;if value then value:changed() end
end
function M.on_settings_changed(host)
    local value=host._native_direct_interval;if value then value:settings_changed() end
end
function M.cancel(host)
    local value=host._native_direct_interval;if value then value:stop() end
end
return M
