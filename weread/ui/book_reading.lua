-- Prepare an uncached book without blocking the native UI event loop.
local Access = require("weread.lib.read_access")
local Content = require("weread.lib.content")
local Source = require("weread.lib.shelf_source")
local WorkerSettings = require("weread.lib.worker_settings")
local UIManager = require("ui/uimanager")
local _ = require("weread.lib.plugin_util").tr
local M = {}

local function integer(value, maximum)
    local n = tonumber(value)
    return n and n >= 0 and n <= maximum and n % 1 == 0 and n or nil
end

-- Only catalog fields needed by downloading/rendering leave the child.
function M.catalog(value)
    if type(value) ~= "table" or #value == 0 or #value > 20000 then return end
    local chapters, seen = {}, {}
    for index, row in ipairs(value) do
        if type(row) ~= "table" then return end
        local uid = Access.book_id(row.chapterUid or row.chapterId)
        if not uid or seen[uid] or type(row.title) ~= "string" or #row.title > 2048
            or row.title:find("[%z%c]") then return end
        seen[uid] = true
        chapters[index] = { chapterUid = uid, title = row.title,
            chapterIdx = integer(row.chapterIdx or row.chapterIndex, 1000000),
            wordCount = integer(row.wordCount, 100000000) or 0,
            level = integer(row.level, 100) or 1 }
    end
    return chapters
end

local function local_hint(value, book_id, owner, account)
    if type(value)~='table' then return {} end
    for _i,key in ipairs({'book_id','bookId'}) do
        if value[key]~=nil and book_id~=nil and tostring(value[key])~=tostring(book_id) then return {} end
    end
    if owner~=nil and account~=nil and tostring(owner)~=tostring(account) then return {} end
    return value
end

-- Shared by cached and uncached Read. File-backed book storage already has an
-- account scope; explicit nested owner/book conflicts must still be ignored.
function M.local_positions(local_book, account)
    local_book=type(local_book)=='table' and local_book or {}
    local id=local_book.book_id or local_book.bookId
    local pending=local_hint(local_book.pending_upload_position,id,
        local_book.pending_upload_account or local_book.recent_read_account,account)
    local recent=local_hint(local_book.last_local_position,id,local_book.recent_read_account,account)
    return {pending,recent}
end

function M.resume_index(chapters, local_book, remote, account)
    local_book=type(local_book)=='table' and local_book or {}
    local positions=M.local_positions(local_book,account)
    local pending,recent=positions[1],positions[2]
    for _i, hint in ipairs({pending,recent,local_book,type(remote)=='table' and remote or {}}) do
        for index, chapter in ipairs(chapters) do
            if hint.chapter_uid ~= nil and tostring(hint.chapter_uid) == tostring(chapter.chapterUid or chapter.chapterId) then return index end
        end
        if hint.chapter_idx ~= nil then
            local wanted=integer(hint.chapter_idx,1000000)
            for index, chapter in ipairs(chapters) do
                local actual=integer(chapter.chapterIdx or chapter.chapterIndex,1000000)
                if wanted~=nil and actual~=nil and wanted==actual then return index end
            end
        end
    end
end

function M.choose(chapters, local_book, remote, account)
    return chapters[M.resume_index(chapters,local_book,remote,account) or 1]
end

local function close_busy(host, context)
    if context.busy and host.busy_message == context.busy then host:closeBusy() end
    context.busy = nil
end

function M.cancel(host)
    local context = host.book_reading_context
    if not context then return end
    host.book_reading_context = nil
    if host.book_reading_worker then host.book_reading_worker:cancel() end
    if context.complete then host.downloader:cancelRequest(context.complete, "reading_cancelled") end
    close_busy(host, context)
end

function M.start(host, book, view)
    if view and host._book_detail_view ~= view then return false end
    -- CB_ catalog/content queries were verified independently before opening
    -- this read path. Chapter IDs and synchronization retain their own gates.
    local id = Access.display_book_id(book.book_id or book.bookId)
    if not id then return false end
    local online
    if host.isNetworkConnected then online = host:isNetworkConnected() else online = host:isNetworkOnline() end
    if not online then host:showOffline(_("Read")); return false end
    if not host:requireLogin(true, false) then return false end
    local access = Source.web_access(host.settings)
    if not access then return false end
    M.cancel(host)
    local context = { epoch = host.discovery_epoch or 0, view = view,
        scope = host.settings:get_auth_scope(), account = host.library_db and host.library_db:accountKey(),
        fingerprint = WorkerSettings.fingerprint(host.settings) }
    host.book_reading_context = context
    local function current()
        return host.book_reading_context == context and (host.discovery_epoch or 0) == context.epoch
            and (not view or host._book_detail_view == view)
            and (not host.library_db or host.library_db:accountKey() == context.account)
            and host.settings:auth_scope_matches(context.scope)
    end
    local function fail()
        if host.book_reading_context ~= context then return end
        if not current() then M.cancel(host); return end
        M.cancel(host)
        host:showInfo(_("Could not prepare this book for reading. Check your connection and login, then try again."))
    end
    host:showBusy(_("Preparing book for reading..."), function() M.cancel(host) end)
    context.busy = host.busy_message
    if not host.book_reading_worker then
        local ok, worker = pcall(function()
            return require("weread.lib.memory_worker"):new{ scheduler = UIManager, codec = host.client,
                max_bytes = 4 * 1024 * 1024 }
        end)
        if not ok then fail(); return false end
        host.book_reading_worker = worker
    end
    local ok, started = pcall(host.book_reading_worker.start, host.book_reading_worker, function()
        local auth_result = WorkerSettings.capture(host.settings)
        local copy = { book_id = id, title = book.title, author = book.author, reader_url = book.reader_url }
        local state = Content.ensure_reader_state(host.client, copy)
        local progress, chapter = state.progress or {}, state.current_chapter or {}
        return { book_id = id, chapters = M.catalog(Content.fetch_catalog(host.client, copy)), auth = auth_result(),
            remote = { chapter_uid = progress.chapterUid or chapter.chapterUid,
                chapter_idx = progress.chapterIdx or chapter.chapterIdx } }
    end, function(result)
        -- Old worker callbacks must never cancel a replacement request.
        if host.book_reading_context ~= context then return end
        if not current() or WorkerSettings.fingerprint(host.settings) ~= context.fingerprint then M.cancel(host); return end
        local chapters = type(result) == "table" and result.book_id == id and M.catalog(result.chapters)
        if not chapters then fail(); return end
        if result.auth and not WorkerSettings.merge(host.settings, context.fingerprint, result.auth) then fail(); return end
        local latest = host.settings:get_book(id) or book
        local target = M.choose(chapters, latest, result.remote, context.account)
        latest.chapters = chapters
        local saved = pcall(function()
            if host.library_db and not host.library_db:putChapters(id, chapters) then error("catalog_save_failed", 0) end
            if not Content.save_catalog_cache(host.client, host.settings, latest, chapters) then error("catalog_save_failed", 0) end
        end)
        if not saved then fail(); return end
        close_busy(host, context)
        context.complete = function(success, path)
            if host.book_reading_context ~= context then return end
            if not success or not current() then M.cancel(host); return end
            -- The downloader releases its job before the native reader opens.
            UIManager:scheduleIn(0.1, function()
                if host.book_reading_context ~= context then return end
                if not current() then M.cancel(host); return end
                host.book_reading_context = nil
                host:openFile(path,nil,latest)
            end)
        end
        local launched, accepted = pcall(host.downloader.start, host.downloader, latest, { target }, "chapter", {
            single_chapter = true, offer_read = false, silent_completion = true, on_complete = context.complete,
        })
        if not launched then fail() elseif not accepted then M.cancel(host) end
    end)
    if not ok or not started then fail(); return false end
    return true
end

return M
