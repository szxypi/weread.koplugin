local Data = require("weread.lib.shelf_progress")
local M = {}

function M:prepareShelfProgress(books)
    local ids = {}
    for _, book in ipairs(books) do ids[#ids + 1] = tostring(book.bookId or book.book_id) end
    local snapshots = self.library_db and self.library_db.getShelfProgress and self.library_db:getShelfProgress(ids) or {}
    local saved = self.settings:get("books", {})
    local account = self.library_db and self.library_db:accountKey()
    for _, book in ipairs(books) do
        local id = tostring(book.bookId or book.book_id)
        book._shelf_progress, book._shelf_progress_local = Data.display(saved[id], snapshots[tostring(id)], account, id)
    end
    return snapshots
end

function M:cancelShelfProgress()
    local context = self.shelf_progress_context
    self.shelf_progress_context = nil
    if context and context.request and self.shelf_progress_worker then
        self.shelf_progress_worker:cancel(context.request, "view_changed")
    end
    if context and context.web_request then require('weread.ui.web_renewal').cancel(self,context.web_request) end
end

function M:refreshVisibleShelfProgress(view, books, snapshots, options)
    options = options or {}
    local account = self.library_db and self.library_db:accountKey()
    local ids = {}
    for _, book in ipairs(books) do
        local id = Data.book_id(book.bookId or book.book_id)
        if id then ids[#ids + 1] = id end
    end
    local access = Data.selection(self.settings)
    local key = tostring(account) .. ":" .. tostring(self.discovery_epoch or 0) .. ":"
        .. (access and access.revision or "") .. ":" .. table.concat(ids, ",")
    local current = self.shelf_progress_context
    if current and current.is_current and not current.is_current() then
        self:cancelShelfProgress();current=nil
    end
    if current and current.key == key and (current.request or current.renewing) then
        current.redraw = options.on_redraw
        return
    end
    self:cancelShelfProgress()
    if not account or #ids == 0 or not self:isNetworkOnline() or not access then return end
    if self.shelf_progress_retry_at and self.shelf_progress_retry_revision == access.revision
        and os.time() < self.shelf_progress_retry_at then return end
    local needed = {}
    for _, id in ipairs(ids) do
        local cached = snapshots[id]
        if options.force or not cached or os.time() - (tonumber(cached.fetched_at) or 0) >= Data.TTL then
            needed[#needed + 1] = id
        end
    end
    if #needed == 0 then return end
    if not self.shelf_progress_worker then
        self.shelf_progress_worker = require("weread.lib.background_worker"):new{
            temp_dir = self.settings.data_dir .. "/workers", timeout = 30,
        }
    end
    if not self.shelf_progress_worker:available() then return end
    local context = { key = key, redraw = options.on_redraw }
    local epoch = self.discovery_epoch or 0
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
        if context.changed and context.redraw and self.shelf_view then context.redraw() end
    end
    local launch
    launch=function()
    context.generation=(context.generation or 0)+1
    local generation=context.generation
    local batch_access,batch_needed,web_only=access,needed,context.recovery_attempted==true
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
            if #values>0 then
                if not self.library_db:putShelfProgress(values) then finish(true);return end
                context.changed=true
            end
            -- Keep the valid prefix, then resume only the failed suffix. Do
            -- not redraw into a new request while renewal owns this context.
            if result.value.web_expired and not context.recovery_attempted then
                local index=result.value.next_index
                if type(index)~='number' or index%1~=0 or index<1 or index>#needed or #values~=index-1 then finish(true);return end
                for i,snapshot in ipairs(values) do if snapshot.book_id~=needed[i] then finish(true);return end end
                context.recovery_attempted,context.renewing=true,true
                local remaining={};for i=index,#needed do remaining[#remaining+1]=needed[i] end
                local Renewal=require('weread.ui.web_renewal')
                local started,request=Renewal.run(self,{is_current=owner_current},function(ok,reason)
                    if not owner_current() or not context.renewing or context.generation~=generation then return end
                    context.web_request,context.renewing=nil,false
                    if reason=='session_changed' then self:cancelShelfProgress();return end
                    if not ok then
                        finish(true)
                        if self.showTransientInfo then self:showTransientInfo(Renewal.error_text(reason),4) end
                        return
                    end
                    local fresh=Data.selection(self.settings)
                    if not fresh or not fresh.web or not owner_current() then self:cancelShelfProgress();return end
                    -- Only access may change; view, account and reader owners
                    -- remain bound to the original visible batch.
                    access,needed=fresh,remaining
                    context.key=tostring(account)..':'..tostring(epoch)..':'..access.revision..':'..table.concat(ids,',')
                    launch()
                end)
                if self.shelf_progress_context==context and context.renewing then
                    if started then context.web_request=request else context.renewing=false;finish(true) end
                elseif started then Renewal.cancel(self,request) end
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
