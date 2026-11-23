-- Optional background reporting for the current native reader session. The
-- existing transfer journal remains the only authority to claim/send time.
local UI=require('ui/uimanager')
local C=require('weread.lib.readtime_transfer_contract')
local Path=require('weread.lib.native_direct_path')
local Account=require('weread.lib.native_position_contract').account_key
local _=require('weread.lib.plugin_util').tr
local M={INTERVAL=300};M.__index=M

function M:new(host,options)
    options=options or {}
    local interval=options.interval or M.INTERVAL
    assert(type(interval)=='number' and interval%1==0 and interval>=1 and interval<=3600)
    return setmetatable({host=host,scheduler=options.scheduler or UI,now=options.now or os.time,interval=interval,
        worker_factory=options.worker_factory,service_factory=options.service_factory,
        select=options.select,scan=options.scan,visible=options.visible},self)
end

function M:enabled()
    local value=self.host.settings:get('offline_time',{})
    return type(value)=='table' and value.enabled==true and value.auto_native==true
end

function M:current()
    local h,c=self.host,self.context
    if not c or h._native_auto_time~=self or not self:enabled() or h._weread_suspended
        or h.ui~=c.reader or c.reader.document~=c.document or c.document.file~=c.file
        or (h._reader_session_gen or 0)~=c.session or not h.settings:auth_scope_matches(c.scope)
        or h.library_db:accountKey()~=c.account then return false end
    local ok,online=pcall(h.isNetworkConnected,h)
    return ok and online==true
end

function M:stop(blocked,message)
    local h=self.host
    if self.timer then self.scheduler:unschedule(self.timer);self.timer=nil end
    self.context,self.operation=nil,nil
    if h._native_auto_time==self then h._native_auto_time=nil end
    if self.worker then self.worker:cancel() end
    if self.service then self.service:cancel() end
    if blocked then
        h._native_auto_time_blocked=true
        if message and h.showTransientInfo then h:showTransientInfo(_(message),3) end
    end
end

function M:schedule()
    if not self:current() then self:stop();return false end
    if self.timer or self.operation then return true end
    local start=self.now();local task
    task=function()
        if self.timer~=task then return end
        if not self:current() then self:stop();return end
        local now=self.now()
        if now<start then self.timer=nil;self:schedule();return end
        if now<start+self.interval then self.scheduler:scheduleIn(start+self.interval-now,task);return end
        self.timer=nil;self:run()
    end
    self.timer=task;self.scheduler:scheduleIn(self.interval,task);return true
end

function M:work(task,done)
    if not self.worker then
        local ok,worker=pcall(function()
            return self.worker_factory and self.worker_factory(self) or require('weread.lib.memory_worker'):new{
                scheduler=self.scheduler,codec=self.host.client,timeout=180}
        end)
        if not ok or not worker then self:stop(true,'Automatic reading-time sync paused. Check local reading time.');return end
        self.worker=worker
    end
    local token={};self.operation=token
    local ok,started=pcall(self.worker.start,self.worker,task,function(value)
        if self.operation~=token then return end
        self.operation=nil
        if not self:current() then self:stop();return end
        done(value)
    end)
    if not ok or not started then
        if self.operation==token then self:stop(true,'Automatic reading-time sync paused. Check local reading time.') end
    end
end

function M:run()
    if not self:current() then self:stop();return end
    local h,c=self.host,self.context
    local visible=self.visible and self.visible(h) or not self.visible and UI:getTopmostVisibleWidget()==c.reader
    local active=h.offline_time and h.offline_time.active
    if not visible or h.busy_message or not active or active.account~=c.account or active.document~=c.document
        or not C.id(active.book_id) or not C.hash(active.native_time_file_id) then self:schedule();return end
    local book=active.book_id
    self:work(function()
        if self.select then return self.select(h,c,book) end
        local journal=require('weread.lib.readtime_transfer_store'):new{
            ledger=h.offline_time.store,coverage=h.readtime_coverage,codec=h.client}
        local pending,reason=journal:pending(c.account)
        if pending then return {pending=true} end
        if reason then return {error='storage'} end
        return require('weread.lib.readtime_transfer_queue'):new{ledger=h.offline_time.store,coverage=h.readtime_coverage,now=self.now}
            :select(c.account,book,{current_day=true,allow_native=true})
    end,function(result)
        if type(result)=='table' and result.pending==true then
            self:stop(true,'Automatic reading-time sync needs review. Open local reading time.');return
        end
        if type(result)~='table' or result.error then
            self:stop(true,'Automatic reading-time sync paused. Check local reading time.');return
        end
        local selection=result.selection
        if selection==false then self:schedule();return end
        if type(selection)~='table' or selection.book_id~=book or selection.native_direct~=true
            or selection.current_day~=true or not C.hash(selection.file_id) then
            self:stop(true,'Automatic reading-time sync paused. Check local reading time.');return
        end
        local scan
        scan=function(cursor,prior)
            self:work(function()
                if self.scan then return self.scan(h,c,selection,cursor,prior) end
                return require('weread.lib.native_direct_readtime_source').scan_page(
                    h.settings,c.account,c.scope,selection,cursor,prior,function() return self:current() end)
            end,function(page)
                if type(page)=='table' and page.kind=='more' and page.cursor==cursor+32 and page.cursor<=2001 then
                    scan(page.cursor,page.prior);return
                end
                local ref=type(page)=='table' and page.kind=='found' and page.reference
                if type(ref)~='table' or ref.kind~='native_direct' or type(ref.file)~='string'
                    or not C.id(ref.chapter_uid) or not C.hash(ref.source_sha256) then
                    self:stop(true,'Automatic reading-time sync paused. Check local reading time.');return
                end
                self:send(selection,ref)
            end)
        end
        scan(1,nil)
    end)
end

function M:send(selection,ref)
    if not self:current() then self:stop();return end
    local h,c=self.host,self.context
    if not self.service then
        local ok,service=pcall(function()
            if self.service_factory then return self.service_factory(self) end
            local journal=require('weread.lib.readtime_transfer_store'):new{
                ledger=h.offline_time.store,coverage=h.readtime_coverage,codec=h.client}
            return require('weread.lib.readtime_transfer_service'):new{
                settings=h.settings,client=h.client,scheduler=self.scheduler,journal=journal,
                task_options={allow_current_native=true},acquire=function(book)
                    return require('weread.lib.readtime_transfer_lease').acquire(h,book,function() return self:current() end)
                end}
        end)
        if not ok or not service then self:stop(true,'Automatic reading-time sync paused. Check local reading time.');return end
        self.service=service
    end
    local token={};self.operation=token
    local ok,started,reason=pcall(self.service.start,self.service,'send',c.account,selection,{ref},
        function() return self:current() end,function(result)
            if self.operation~=token then return end
            self.operation=nil
            if not self:current() then self:stop();return end
            if type(result)=='table' and result.kind=='confirmed' then self:schedule()
            elseif type(result)=='table' and result.kind=='position_required' then
                self:stop(true,'Sync this page to the cloud before transferring this book’s saved reading time.')
            else self:stop(true,'Automatic reading-time sync needs review. Open local reading time.') end
        end)
    if not ok or not started then
        if self.operation~=token then return end
        self.operation=nil
        if ok and (reason=='busy' or reason=='position_pending') then self:schedule()
        else self:stop(true,'Automatic reading-time sync needs review. Open local reading time.') end
    end
end

function M.start(host,reset,options)
    if reset then host._native_auto_time_blocked=nil end
    if host._native_auto_time then return host._native_auto_time:schedule() end
    if not host.settings or type(host.settings.get_auth_scope)~='function' then return false end
    local reader=host.ui;local doc=reader and reader.document;local scope=host.settings:get_auth_scope()
    local account=host.library_db and host.library_db:accountKey()
    if host._native_auto_time_blocked or not Path.contains(host.settings,doc and doc.file)
        or not scope or not C.account(account) or Account(scope.vid)~=account
        or not host.settings:auth_scope_matches(scope) then return false end
    local auto=M:new(host,options)
    if not auto:enabled() then return false end
    auto.context={reader=reader,document=doc,file=doc.file,scope=scope,account=account,session=host._reader_session_gen or 0}
    host._native_auto_time=auto
    return auto:schedule()
end
function M.cancel(host)
    local value=host._native_auto_time;if value then value:stop() end
end
return M
