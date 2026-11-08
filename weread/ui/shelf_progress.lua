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
end

function M:refreshVisibleShelfProgress(view, books, snapshots, options)
    options = options or {}
    local account = self.library_db and self.library_db:accountKey()
    local ids = {}
    for _, book in ipairs(books) do ids[#ids + 1] = tostring(book.bookId or book.book_id) end
    local key = tostring(account) .. ":" .. tostring(self.discovery_epoch or 0) .. ":" .. table.concat(ids, ",")
    local current = self.shelf_progress_context
    if current and current.key == key and current.request then
        current.redraw = options.on_redraw
        return
    end
    self:cancelShelfProgress()
    if not account or #ids == 0 or not self:isNetworkOnline()
        or not self.settings:is_api_configured() then return end
    if self.shelf_progress_retry_at and os.time() < self.shelf_progress_retry_at then return end
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
    self.shelf_progress_context = context
    local started, request = self.shelf_progress_worker:start{
        kind = "shelf_progress", queue = true, replace_active = true,
        task = function(worker_context) return Data.fetch(self.client, needed, worker_context) end,
        on_done = function(result)
            if self.shelf_progress_context ~= context or self.library_db:accountKey() ~= account
                or (self.discovery_epoch or 0) ~= epoch then return end
            context.request = nil
            if not result.ok or type(result.value) ~= "table" then
                self.shelf_progress_retry_at = os.time() + 30
                return
            end
            if result.value.failed then self.shelf_progress_retry_at = os.time() + 30 end
            local values = result.value.snapshots
            if type(values) == "table" and #values > 0 and self.library_db:putShelfProgress(values) then
                if context.redraw and self.shelf_view then context.redraw() end
            end
        end,
    }
    if started then context.request = request end
end

return M
