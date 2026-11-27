local Data = require("weread.lib.shelf_progress")
local Recovery = require("weread.ui.shelf_progress_recovery")
local Access = require("weread.lib.read_access")
local Identity = require("weread.lib.shelf_snapshot")
local NetworkLink = require("weread.lib.network_link")
local M = {}

function M:prepareShelfProgress(books,saved_books)
    local ids = {}
    for _, book in ipairs(books) do
        local id=Identity.persisted_id(book)
        if id and Data.book_id(id) then ids[#ids + 1]=id end
    end
    local raw = self.library_db and self.library_db.getShelfProgress and self.library_db:getShelfProgress(ids) or {}
    local snapshots={}
    for _,id in ipairs(ids) do
        local snapshot=type(raw)=='table' and raw[id]
        if type(snapshot)=='table' and Identity.persisted_identity(snapshot.book_id)==id then snapshots[id]=snapshot end
    end
    local saved = saved_books or Access.book_lookup(self.settings)
    local account = self.library_db and self.library_db:accountKey()
    for _, book in ipairs(books) do
        local id = Identity.persisted_id(book)
        local local_book = id and Access.cached_book(saved,id)
        book._shelf_progress, book._shelf_progress_local, book._shelf_progress_exact =
            Data.display(local_book, id and snapshots[id], account, id)
    end
    return snapshots
end

function M:cancelShelfProgress()
    local all=package.loaded['weread.ui.shelf_progress_all']
    if all then all.cancel(self) end
    local context = self.shelf_progress_context
    self.shelf_progress_context = nil
    if context and context.request and self.shelf_progress_worker then
        self.shelf_progress_worker:cancel(context.request, "view_changed")
    end
    if context then Recovery.cancel(self, context) end
end

function M:refreshVisibleShelfProgress(view, books, snapshots, options)
    options = options or {}
    local account = self.library_db and self.library_db:accountKey()
    local epoch = self.discovery_epoch or 0
    local ids = {}
    for _, book in ipairs(books) do
        local id = Identity.persisted_id(book)
        id=id and Data.book_id(id)
        if id then ids[#ids + 1] = id end
    end
    local view_key = tostring(account) .. ":" .. tostring(epoch) .. ":" .. table.concat(ids, ",")
    local current = self.shelf_progress_context
    if current and current.is_current and not current.is_current() then
        self:cancelShelfProgress();current=nil
    end
    -- A pending native renewal temporarily hides the grant from read selection.
    -- Keep ownership across redraws of the same visible books.
    local same_view = current and current.view_key == view_key
    local access = same_view and current.renewing and current.access or Data.selection(self.settings)
    if same_view and (current.renewing or current.request and access and current.access.revision == access.revision) then
        current.redraw = options.on_redraw
        current.snapshots = snapshots
        current.view = view
        return
    end
    self:cancelShelfProgress()
    if not account or #ids == 0 or not access then return end
    if self.shelf_progress_retry_at and self.shelf_progress_retry_revision == access.revision
        and os.time() < self.shelf_progress_retry_at then return end
    local needed = {}
    for _, id in ipairs(ids) do
        local cached = snapshots[id]
        if Data.supports(id, access) and
            (options.force or not cached or os.time() - (tonumber(cached.fetched_at) or 0) >= Data.TTL) then
            needed[#needed + 1] = id
        end
    end
    if #needed == 0 then return end
    if not NetworkLink.available(self) then return end
    if not self.shelf_progress_worker then
        self.shelf_progress_worker = require("weread.lib.background_worker"):new{
            temp_dir = self.settings.data_dir .. "/workers", timeout = 30,
        }
    end
    if not self.shelf_progress_worker:available() then return end
    local context = { view_key = view_key, access = access, redraw = options.on_redraw, snapshots = snapshots, view = view }
    local saved_progress = {}
    local document=self.ui and self.ui.document
    local file=document and document.file
    local session,cache=self._reader_session_gen,self.settings.cache_dir
    local api_key=self.settings:get('api_key','')
    local scope=self.settings.get_auth_scope and self.settings:get_auth_scope()
    self.shelf_progress_context = context
    local function owner_current()
        return self.shelf_progress_context==context and self.library_db:accountKey()==account
            and (self.discovery_epoch or 0)==epoch and document==(self.ui and self.ui.document)
            and file==(self.ui and self.ui.document and self.ui.document.file)
            and session==self._reader_session_gen and cache==self.settings.cache_dir
            and api_key==self.settings:get('api_key','')
            and (not scope or self.settings:auth_scope_matches(scope))
    end
    context.is_current=owner_current
    local function failed()
        self.shelf_progress_retry_at=os.time()+30
        self.shelf_progress_retry_revision=access.revision
    end
    local function finish(failure)
        if not owner_current() then return end
        context.renewing=false
        if failure then failed() end
        local visible = context.view and context.view._visible_status_snapshots or context.snapshots
        local changed = false
        for id, snapshot in pairs(saved_progress) do
            local before, _, before_exact = Data.display(nil, visible[id] or context.snapshots[id])
            local after, _, after_exact = Data.display(nil, snapshot)
            -- Exact zero and unknown legacy zero render alike, but filter differently.
            if before ~= after or before_exact ~= after_exact then
                changed = true
            else
                -- Keep the live scroll viewport's expiry current without rebuilding it.
                visible[id] = snapshot
            end
        end
        if changed and context.redraw and self.shelf_view then context.redraw() end
    end
    local launch
    launch=function()
    context.generation=(context.generation or 0)+1
    local generation=context.generation
    local batch_access,batch_needed,web_only=access,needed,context.web_only
    local delivered=false
    local called, started, request = pcall(self.shelf_progress_worker.start,self.shelf_progress_worker,{
        kind = "shelf_progress", queue = true, replace_active = true,
        task = function(worker_context) return Data.fetch(self.client, batch_needed, worker_context, batch_access,
            {web_only=web_only}) end,
        on_done = function(result)
            if delivered then return end;delivered=true
            if not owner_current() or context.generation~=generation then return end
            context.request = nil
            if not Data.matches(self.settings, access) then return end
            if type(result)~='table' or not result.ok or type(result.value) ~= "table" then
                finish(true)
                return
            end
            if result.value.stale then return end
            local values = result.value.snapshots
            if type(values)~='table' then finish(true);return end
            local channel=Recovery.channel(context,result.value)
            local index=result.value.next_index
            if channel then
                if type(index)~='number' or index%1~=0 or index<1 or index>#needed or #values~=index-1 then finish(true);return end
                for i,snapshot in ipairs(values) do
                    if type(snapshot)~='table' or snapshot.book_id~=needed[i] then finish(true);return end
                end
            end
            if #values>0 then
                if not self.library_db:putShelfProgress(values) then finish(true);return end
                for _, snapshot in ipairs(values) do saved_progress[snapshot.book_id] = snapshot end
            end
            -- Keep the valid prefix, then resume only the failed suffix. Do
            -- not redraw into a new request while renewal owns this context.
            if channel then
                local remaining={};for i=index,#needed do remaining[#remaining+1]=needed[i] end
                local started=Recovery.start(self,context,access,channel,{
                    is_current=function() return owner_current() and context.generation==generation end,
                    stale=function() if self.shelf_progress_context==context then self:cancelShelfProgress() end end,
                    complete=function(ok,fresh,resumed_web_only,message)
                        if not ok then
                            finish(true)
                            if message and self.showTransientInfo then self:showTransientInfo(message,4) end
                            return
                        end
                        access,needed=fresh,remaining
                        context.access,context.web_only=access,resumed_web_only
                        launch()
                    end,
                })
                if not started then finish(true) end
                return
            end
            finish(result.value.failed)
        end,
    })
    if called and started then
        if not delivered then
            if owner_current() then context.request=request else self.shelf_progress_worker:cancel(request,'view_changed') end
        end
    elseif not delivered then finish(true) end
    end
    launch()
end

return M
