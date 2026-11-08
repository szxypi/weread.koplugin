-- Async display metadata; the parent alone persists sanitized fields and UI.
local Access = require("weread.lib.read_access")
local Metadata = require("weread.lib.book_metadata")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local M = {}

local function close_busy(host, context)
    if context.busy and host.busy_message == context.busy then host:closeBusy() end
end

function M.cancel(host)
    local context = host.book_metadata_context
    if not context then return end
    host.book_metadata_context = nil
    if host.book_metadata_worker then host.book_metadata_worker:cancel() end
    close_busy(host, context)
end

function M.refresh(host, book, old_view, options)
    options = options or {}
    if old_view and host._book_detail_view ~= old_view then return false end
    M.cancel(host)
    local id = Access.book_id(book.book_id or book.bookId)
    local access = Access.capture(host.settings)
    if not id then return false end
    if not host:isNetworkOnline() then
        if options.automatic then host:showBookMenu(book) else host:showOffline(_("Book info")) end
        return false
    end
    if not access then
        if options.automatic then host:showBookMenu(book) end
        host:showTransientInfo(_("Please scan the QR code to log in first."), 2)
        UIManager:scheduleIn(0.2, function() host.qr_login:start() end)
        return false
    end
    local context = { epoch = host.discovery_epoch or 0,
        account = host.library_db and host.library_db:accountKey(), view = old_view }
    host.book_metadata_context = context
    local function current()
        return host.book_metadata_context == context and (host.discovery_epoch or 0) == context.epoch
            and (not host.library_db or host.library_db:accountKey() == context.account)
            and (not old_view or host._book_detail_view == old_view)
            and Access.matches(host.settings, access)
    end
    local function finish()
        host.book_metadata_context = nil
        close_busy(host, context)
    end
    local function failed()
        if options.automatic then host:showBookMenu(book) end
        host:showTransientInfo(_("Book information could not be updated. Showing cached details."), 3)
    end
    host:showBusy(_("Loading book info..."), function() M.cancel(host) end)
    context.busy = host.busy_message
    if not host.book_metadata_worker then
        local ok, worker = pcall(function()
            return require("weread.lib.memory_worker"):new{ scheduler = UIManager, codec = host.client, max_bytes = 256 * 1024 }
        end)
        if ok then host.book_metadata_worker = worker else finish(); failed(); return false end
    end
    local ok, started = pcall(host.book_metadata_worker.start, host.book_metadata_worker,
        function() return Metadata.fetch(host.client, id, access) end,
        function(result)
            if not current() then
                if host.book_metadata_context == context then M.cancel(host) end
                return
            end
            finish()
            local valid, metadata = pcall(Metadata.normalize, type(result) == "table" and result.metadata, id)
            if not valid or (result.source ~= "gateway" and result.source ~= "web") then failed(); return end
            -- Re-read after the network task: reading and downloads may have
            -- changed local state while the metadata request was outstanding.
            local committed, latest = pcall(function()
                local books = host.settings:get("books", {})
                local saved = books[id] or { book_id = id }
                for key, value in pairs(metadata) do saved[key] = value end
                saved.book_id, saved._library_account_key = id, context.account
                saved.detail_updated_at, saved.detail_source = os.time(), result.source
                if host.library_db and not host.library_db:putBook(saved) then error("metadata_save_failed", 0) end
                books[id] = saved
                host.settings:set("books", books)
                host.settings:flush()
                return saved
            end)
            if not committed then
                host:showInfo(_("Could not save book information. Check storage and try again."))
                return
            end
            if old_view then UIManager:close(old_view) end
            host:showBookMenu(latest)
            host:showTransientInfo(_("Book information updated."), 2)
        end)
    if not ok or not started then
        if host.book_metadata_context == context then M.cancel(host); failed() end
        return false
    end
    return true
end

return M
