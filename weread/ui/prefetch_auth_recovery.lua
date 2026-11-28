-- One silent, session-bound Web renewal for an expired chapter prefetch.
local UIManager=require('ui/uimanager')
local Access=require('weread.lib.read_access')
local Auth=require('weread.lib.web_authorization')
local WorkerSettings=require('weread.lib.worker_settings')
local FileIdentity=require('weread.lib.book_file_identity')
local M={}

local function catalog(value) return require('weread.ui.book_reading').catalog(value) end

local function same_chapter(expected,chapters)
    for _,row in ipairs(chapters or {}) do
        if row.chapterUid==expected.chapterUid then
            return row.title==expected.title and (expected.chapterIdx==nil or row.chapterIdx==expected.chapterIdx)
                and (expected.wordCount==0 or row.wordCount==expected.wordCount) and row.level==expected.level
        end
    end
    return false
end

function M.matches(expected,chapter)
    local normalized=type(chapter)=='table' and catalog({chapter})
    return type(expected)=='table' and normalized~=nil and same_chapter(expected,normalized)
end

function M.cancel(host)
    local owner=host._prefetch_auth_recovery
    host._prefetch_auth_recovery=nil
    if not owner then return false end
    if owner.task and UIManager.unschedule then UIManager:unschedule(owner.task) end
    if owner.job and owner.service then owner.service:cancel(owner.job) end
    if owner.worker then owner.worker:cancel() end
    return true
end

function M.start(host,book,chapter)
    local id=type(book)=='table' and Access.display_book_id(book.book_id or book.bookId)
    local uid=type(chapter)=='table' and Access.book_id(chapter.chapterUid or chapter.chapterId)
    local selected=type(chapter)=='table' and catalog({chapter})
    local settings=host.settings
    local document=host.ui and host.ui.document
    local scope=settings and settings.get_auth_scope and settings:get_auth_scope()
    if not id or not uid or not selected or not document or not scope or not settings:auth_scope_matches(scope)
        or host._current_weread_book_id~=id or host._prefetch_auth_recovery then return false end
    local ok,input=pcall(Auth.capture,settings)
    if not ok or type(input)~='table' or type(input.revision)~='string'
        or type(input.scope)~='table' or input.scope.vid~=scope.vid or input.scope.epoch~=scope.epoch then return false end
    local fingerprint=WorkerSettings.fingerprint(settings)
    local key=table.concat({scope.vid,tostring(scope.epoch),id,uid,tostring(host._reader_session_gen)},':')
    host._prefetch_auth_attempts=host._prefetch_auth_attempts or {}
    if host._prefetch_auth_attempts[key] then return false end
    local owner={book_id=id,chapter_uid=uid,document=document,file=document.file,scope=scope,
        session=host._reader_session_gen,api_key=settings:get('api_key',''),revision=input.revision,
        chapter=selected[1],version=FileIdentity.version(book.bookVersion)}
    host._prefetch_auth_recovery=owner
    local function current()
        local cache=settings:get('cache',{})
        local active=host.downloader and (host.downloader._active_job or host.downloader._pending_start or host.downloader._scheduled_start)
        return host._prefetch_auth_recovery==owner and host.ui and host.ui.document==document
            and document.file==owner.file and host._reader_session_gen==owner.session
            and host._current_weread_book_id==id and settings:auth_scope_matches(scope)
            and Access.display_book_id(book.book_id or book.bookId)==id
            and Access.book_id(chapter.chapterUid or chapter.chapterId)==uid
            and M.matches(owner.chapter,chapter)
            and FileIdentity.version(book.bookVersion)==owner.version
            and settings:get('api_key','')==owner.api_key and type(cache)=='table' and cache.auto_prefetch_next_chapter==true
            and not active and (not host.isNetworkConnected or host:isNetworkConnected())
    end
    owner.task=function()
        owner.task=nil
        if not current() or WorkerSettings.fingerprint(settings)~=fingerprint or host._web_renewal_request then M.cancel(host);return end
        local available,service=pcall(require('weread.ui.web_renewal').service,host)
        if not available or not service or service.job then M.cancel(host);return end
        owner.service=service
        host._prefetch_auth_attempts[key]=true
        local called,started,job=pcall(service.start,service,{is_current=current,expected_revision=owner.revision},function(success,receipt)
            if host._prefetch_auth_recovery~=owner then return end
            if not success then
                local pending=owner.job or service.job
                if pending and service.job==pending then service:cancel(pending) end
            end
            owner.job=nil
            if not current() or not success then M.cancel(host);return end
            local verified,fresh=pcall(Auth.capture,settings)
            if not verified or type(receipt)~='table' or type(receipt.revision)~='string'
                or #receipt.revision~=64 or not receipt.revision:match('^[0-9a-f]+$')
                or type(fresh)~='table' or fresh.revision~=receipt.revision or type(fresh.scope)~='table'
                or fresh.scope.vid~=scope.vid or fresh.scope.epoch~=scope.epoch then M.cancel(host);return end
            local fingerprint_after=WorkerSettings.fingerprint(settings)
            if not host._prefetch_auth_recovery_worker then
                local made,worker=pcall(function() return require('weread.lib.memory_worker'):new{
                    scheduler=UIManager,codec=host.client,max_bytes=4*1024*1024} end)
                if not made then M.cancel(host);return end
                host._prefetch_auth_recovery_worker=worker
            end
            owner.worker=host._prefetch_auth_recovery_worker
            local launched,started=pcall(owner.worker.start,owner.worker,function()
                local good,value=pcall(function()
                    local auth_result=WorkerSettings.capture(settings)
                    local copy={book_id=id,title=book.title,author=book.author,reader_url=book.reader_url}
                    local client=require('weread.lib.book_reading_client').wrap(host.client,copy)
                    local content=require('weread.lib.content')
                    content.ensure_reader_state(client,copy)
                    local chapters,version=content.fetch_catalog(client,copy)
                    return {book_id=id,chapters=catalog(chapters),version=version or 0,auth=auth_result()}
                end)
                return good and value or {error='unavailable'}
            end,function(result)
                if host._prefetch_auth_recovery~=owner then return end
                if not current() or WorkerSettings.fingerprint(settings)~=fingerprint_after then M.cancel(host);return end
                local version=type(result)=='table' and result.version
                local fresh_chapters=type(result)=='table' and catalog(result.chapters)
                if type(result)~='table' or result.book_id~=id or not fresh_chapters or not same_chapter(owner.chapter,fresh_chapters)
                    or type(version)~='number' or version%1~=0 or version<0 or version>2147483647
                    or owner.version>0 and version>0 and owner.version~=version then M.cancel(host);return end
                if result.auth and not WorkerSettings.merge(settings,fingerprint_after,result.auth) then M.cancel(host);return end
                local recovered={chapter_uid=uid,chapter=owner.chapter,version=version,previous_version=owner.version}
                M.cancel(host)
                host:maybePrefetchNextChapter(id,recovered)
            end)
            if not launched or not started then M.cancel(host) end
        end)
        if host._prefetch_auth_recovery==owner then
            if called and started then owner.job=job else M.cancel(host) end
        elseif called and started and job and service.job==job then service:cancel(job) end
    end
    UIManager:scheduleIn(.1,owner.task)
    return true
end
return M
