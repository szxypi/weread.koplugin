-- Prepare an uncached book without blocking the native UI event loop.
local Access = require("weread.lib.read_access")
local Catalog = require("weread.lib.chapter_catalog")
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
    if type(value) ~= "table" or #value == 0 or #value > Catalog.MAX_CHAPTERS then return end
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
    local recent=local_hint(local_book.last_local_position,id,
        local_book.last_local_account or local_book.recent_read_account,account)
    return {pending,recent}
end

function M.resume_index(chapters, local_book, remote, account)
    local_book=type(local_book)=='table' and local_book or {}
    local positions=M.local_positions(local_book,account)
    local pending,recent=positions[1],positions[2]
    for _i, hint in ipairs({pending,recent,local_book,type(remote)=='table' and remote or {}}) do
        if hint.chapter_uid ~= nil then
            local wanted = tostring(hint.chapter_uid)
            for index, chapter in ipairs(chapters) do
                if wanted == tostring(chapter.chapterUid or chapter.chapterId) then return index end
            end
        end
        if hint.chapter_idx ~= nil then
            local wanted=integer(hint.chapter_idx,1000000)
            local match
            for index, chapter in ipairs(chapters) do
                local actual=integer(chapter.chapterIdx or chapter.chapterIndex,1000000)
                if wanted~=nil and actual~=nil and wanted==actual then
                    -- Chapter indices are not necessarily unique (especially
                    -- zero or incomplete catalog values). Do not silently
                    -- choose the first of several possible resume chapters.
                    if match then match=false;break end
                    match=index
                end
            end
            if match then return match end
        end
    end
end

-- A locally recorded UID remains meaningful even if an old cached catalogue
-- does not contain it. A unique index needs a catalogue to identify its UID.
function M.resume_uid(chapters, local_book, account)
    local_book=type(local_book)=='table' and local_book or {}
    local positions=M.local_positions(local_book,account)
    for _i,hint in ipairs({positions[1],positions[2],local_book}) do
        local uid=Access.book_id(hint.chapter_uid)
        if uid then return uid end
        if type(chapters)=='table' and hint.chapter_idx~=nil then
            local index=M.resume_index(chapters,{pending_upload_position=hint},nil,account)
            local chapter=index and chapters[index]
            if chapter then return Access.book_id(chapter.chapterUid or chapter.chapterId) end
        end
    end
end

function M.choose(chapters, local_book, remote, account)
    return chapters[M.resume_index(chapters,local_book,remote,account) or 1]
end

-- Pass only book metadata and progress from the verified page to the downloader.
local function prepared_reader(url, state)
    local chapter, progress = state.current_chapter or {}, state.progress or {}
    local uid = chapter.chapterUid or progress.chapterUid
    return {
        url = url,
        title = state.title,
        author = state.author,
        current_chapter = {
            chapterUid = (type(uid) == "string" or type(uid) == "number") and uid or nil,
            chapterIdx = tonumber(chapter.chapterIdx or progress.chapterIdx),
            chapterOffset = tonumber(chapter.chapterOffset or progress.chapterOffset),
        },
        progress = {
            progress = tonumber(progress.progress),
            summary = type(progress.summary) == "string" and progress.summary or nil,
        },
    }
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
    if context.web_request then require('weread.ui.web_renewal').cancel(host,context.web_request) end
    if context.recovery_schedule and UIManager.unschedule then UIManager:unschedule(context.recovery_schedule) end
    if context.complete then host.downloader:cancelRequest(context.complete, "reading_cancelled") end
    close_busy(host, context)
    if context.pending_shelf_redraw then require('weread.ui.shelf_popup').resumeMetadata(host,context) end
end

function M.start(host, book, view, origin)
    if view and host._book_detail_view ~= view then return false end
    if origin and not origin.current() then return false end
    -- CB_ catalog/content queries were verified independently before opening
    -- this read path. Chapter IDs and synchronization retain their own gates.
    local id = Access.display_book_id(book.book_id or book.bookId)
    if not id then return false end
    local online
    if host.isNetworkConnected then online = host:isNetworkConnected() else online = host:isNetworkOnline() end
    if not online then host:showOffline(_("Read")); return false end
    local continuation
    if (view or origin) and host.library_db and not host.library_db:accountKey()
        and host.settings.get_auth_scope and not host.settings:get_auth_scope() then
        local epoch,auth_epoch=host.discovery_epoch or 0,host.settings:get('auth_epoch',0)
        local session,document=host._reader_session_gen,host.ui and host.ui.document
        local selected={book_id=id}
        -- Retain public display metadata only, never local or account state.
        if origin then
            for _,key in ipairs({'title','author'}) do
                local value=book[key]
                if type(value)=='string' and #value<=2048 and not value:find('[%z%c]') then selected[key]=value end
            end
        end
        continuation={
            current=function()
                return (not view or host._book_detail_view==view)
                    and (not origin or origin.current()) and (host.discovery_epoch or 0)==epoch
                    and host._reader_session_gen==session and (host.ui and host.ui.document)==document
                    and not host.library_db:accountKey() and not host.settings:get_auth_scope()
                    and host.settings:get('auth_epoch',0)==auth_epoch
            end,
            resume=function() return host:startBookReading(selected) end,
        }
    end
    if not host:requireLogin(true, false, continuation) then return false end
    local access = Source.web_access(host.settings)
    if not access then return false end
    M.cancel(host)
    local document=host.ui and host.ui.document
    local context = { epoch = host.discovery_epoch or 0, view = view, shelf_owner = origin and origin.owner,
        scope = host.settings:get_auth_scope(), account = host.library_db and host.library_db:accountKey(),
        fingerprint = WorkerSettings.fingerprint(host.settings), api_key=host.settings:get('api_key',''),
        document=document, file=document and document.file, session=host._reader_session_gen }
    host.book_reading_context = context
    local function current()
        local now_document=host.ui and host.ui.document
        return host.book_reading_context == context and (host.discovery_epoch or 0) == context.epoch
            and (not view or host._book_detail_view == view)
            and (not origin or origin.current())
            and (not host.library_db or host.library_db:accountKey() == context.account)
            and host.settings:auth_scope_matches(context.scope)
            and host.settings:get('api_key','')==context.api_key
            and now_document==context.document and (not now_document or now_document.file==context.file)
            and host._reader_session_gen==context.session
    end
    local function fail(message)
        if host.book_reading_context ~= context then return end
        if not current() then M.cancel(host); return end
        M.cancel(host)
        host:showInfo(_(message or "Could not prepare this book for reading. Check your connection and login, then try again."))
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
    local launch, recover
    recover=function()
        context.recovery_schedule=nil
        if not current() then M.cancel(host);return end
        if WorkerSettings.fingerprint(host.settings)~=context.fingerprint then M.cancel(host);return end
        if context.recovery_attempted then
            fail('WeRead login expired. Please sign in again and retry.');return
        end
        context.recovery_attempted,context.renewing=true,true
        if not context.busy then
            host:showBusy(_('Renewing WeRead login…\nTap or press a key to cancel.'),function() M.cancel(host) end)
            context.busy=host.busy_message
        end
        local Renewal=require('weread.ui.web_renewal')
        local called,started,request=pcall(Renewal.run,host,{is_current=function()
            return current() and (not host.isNetworkOnline or host:isNetworkOnline())
        end},function(ok,receipt)
            if host.book_reading_context~=context then return end
            context.web_request,context.renewing=nil,false
            if not current() or receipt=='session_changed' then M.cancel(host);return end
            if not ok then M.cancel(host);host:showInfo(Renewal.error_text(receipt));return end
            local verified,fresh=pcall(require('weread.lib.web_authorization').capture,host.settings)
            if not verified or type(receipt)~='table' or type(receipt.revision)~='string'
                or #receipt.revision~=64 or not receipt.revision:match('^[0-9a-f]+$')
                or type(fresh)~='table' or fresh.revision~=receipt.revision or type(fresh.scope)~='table' or fresh.scope.vid~=context.scope.vid or fresh.scope.epoch~=context.scope.epoch
                or not Source.web_access(host.settings) then M.cancel(host);return end
            context.fingerprint=WorkerSettings.fingerprint(host.settings)
            launch()
        end)
        if host.book_reading_context==context and context.renewing then
            if called and started then context.web_request=request
            else context.renewing=false;fail() end
        elseif called and started and request then Renewal.cancel(host,request) end
    end
    launch=function()
        context.generation=(context.generation or 0)+1
        local generation=context.generation
        local ok,started=pcall(host.book_reading_worker.start,host.book_reading_worker,function()
            local good,value=pcall(function()
                local auth_result=WorkerSettings.capture(host.settings)
                local copy={book_id=id,title=book.title,author=book.author,reader_url=book.reader_url}
                local client=require('weread.lib.book_reading_client').wrap(host.client,copy)
                local state=Content.ensure_reader_state(client,copy)
                local progress,chapter=state.progress or {},state.current_chapter or {}
                local chapters,version=Content.fetch_catalog(client,copy)
                return {book_id=id,chapters=M.catalog(chapters),source_version=version or 0,auth=auth_result(),
                    reader=prepared_reader(copy.reader_url,state),
                    remote={chapter_uid=progress.chapterUid or chapter.chapterUid,chapter_idx=progress.chapterIdx or chapter.chapterIdx}}
            end)
            if good then return value end
            return {error=value=='book_reading/web_expired' and 'web_expired'
                or value=='download_read/rate_limited' and 'rate_limited' or 'unavailable'}
        end,function(result)
            if host.book_reading_context~=context or generation~=context.generation then return end
            if not current() or WorkerSettings.fingerprint(host.settings)~=context.fingerprint then M.cancel(host);return end
            if type(result)=='table' and result.error=='web_expired' then recover();return end
            if type(result)=='table' and result.error=='rate_limited' then
                fail('WeRead is limiting requests. Download stopped. Please try again later.');return
            end
            local chapters=type(result)=='table' and result.book_id==id and M.catalog(result.chapters)
            if not chapters or type(result.source_version)~='number' or result.source_version%1~=0
                or result.source_version<0 or result.source_version>2147483647 then fail();return end
            if result.auth and not WorkerSettings.merge(host.settings,context.fingerprint,result.auth) then fail();return end
            context.fingerprint=WorkerSettings.fingerprint(host.settings)
            local latest=host.settings:get_book(id) or book
            local target=M.choose(chapters,latest,result.remote,context.account)
            latest.chapters=chapters
            local saved=pcall(function()
                local encoded=Content.encode_catalog_cache(host.client,chapters)
                if not encoded or host.library_db and not host.library_db:putChapters(id,chapters,encoded) then
                    error('catalog_save_failed',0)
                end
                if not Content.save_catalog_cache(host.client,host.settings,latest,chapters,encoded) then error('catalog_save_failed',0) end
            end)
            if not saved then fail();return end
            close_busy(host,context)
            local download_book
            context.complete=function(success,path)
                if host.book_reading_context~=context then return end
                if not current() or WorkerSettings.fingerprint(host.settings)~=context.fingerprint then M.cancel(host);return end
                if not success then
                    if path=='web_expired' then
                        context.recovery_schedule=function() if host.book_reading_context==context then recover() end end
                        UIManager:scheduleIn(0.1,context.recovery_schedule)
                    else M.cancel(host) end
                    return
                end
                UIManager:scheduleIn(0.1,function()
                    if host.book_reading_context~=context then return end
                    if not current() then M.cancel(host);return end
                    host.book_reading_context=nil;host:openFile(path,nil,download_book)
                end)
            end
            download_book={};for key,value in pairs(latest) do download_book[key]=value end
            download_book.bookVersion=result.source_version
            local reader=type(result.reader)=="table" and result.reader or nil
            if reader then reader.fingerprint=context.fingerprint end
            local launched,accepted=pcall(host.downloader.start,host.downloader,download_book,{target},'chapter',{
                single_chapter=true,offer_read=false,silent_completion=true,on_complete=context.complete,reading_auth_recovery=true,
                prepared_reader=reader,
                on_reading_auth_updated=function(before,after)
                    if current() and context.fingerprint==before and Source.web_access(host.settings) then
                        context.fingerprint=after
                    end
                end,
            })
            if not launched then fail() elseif not accepted then M.cancel(host) end
        end)
        if not ok or not started then fail();return false end
        return true
    end
    if not launch() then return false end
    return true
end

return M
