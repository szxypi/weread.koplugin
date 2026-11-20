-- Load a book's chapter list off the UI thread; renew one definite Web 401.
local UIManager=require('ui/uimanager')
local Content=require('weread.lib.content')
local ReaderContext=require('weread.lib.reader_context')
local Source=require('weread.lib.shelf_source')
local WorkerSettings=require('weread.lib.worker_settings')
local _=require('weread.lib.plugin_util').tr
local M={}

local function valid_catalog(chapters)
    if type(chapters)~='table' or #chapters>20000 then return false end
    local count,seen=0,{}
    for key in pairs(chapters) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#chapters then return false end
        count=count+1
    end
    if count~=#chapters then return false end
    for _,chapter in ipairs(chapters) do
        if type(chapter)~='table' then return false end
        local ok,id=pcall(ReaderContext.identifier,chapter.chapterUid or chapter.chapterId,true)
        if not ok or seen[id] then return false end
        seen[id]=true
        if chapter.title~=nil and (type(chapter.title)~='string' or #chapter.title>8192 or chapter.title:find('[%z%c]')) then return false end
        if chapter.tar~=nil and (type(chapter.tar)~='string' or #chapter.tar>8192 or chapter.tar:find('[%z%c]')) then return false end
    end
    return true
end

function M.cancel(host,view)
    local ctx=host._catalog_request
    if not ctx or view and ctx.chapter_view~=view then return end
    host._catalog_request=nil
    if host._catalog_request_worker then host._catalog_request_worker:cancel() end
    if ctx.request then require('weread.ui.web_renewal').cancel(host,ctx.request) end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end

function M.start(host,book,callback,options)
    options=options or {}
    M.cancel(host)
    local valid,id=pcall(ReaderContext.book_id,book)
    local scope=host.settings:get_auth_scope()
    if not valid or not scope or not Source.web_access(host.settings) then
        host:showInfo(_('Could not load this book’s chapter list. Check your connection and login, then try again.'))
        return false
    end
    local ctx={scope=scope,chapter_view=options.chapter_view,api_key=host.settings:get('api_key',''),
        fingerprint=WorkerSettings.fingerprint(host.settings)}
    host._catalog_request=ctx
    local function current()
        local same,book_id=pcall(ReaderContext.book_id,book)
        local page_ok,page=true,true
        if options.current then page_ok,page=pcall(options.current) end
        return same and book_id==id and page_ok and page==true and host._catalog_request==ctx
            and (not ctx.chapter_view or host._chapter_list_view==ctx.chapter_view and not ctx.chapter_view._catalog_closed)
            and host.settings:auth_scope_matches(scope) and host.settings:get('api_key','')==ctx.api_key
    end
    local function fail(message)
        if host._catalog_request~=ctx then return end
        local live=current();M.cancel(host)
        if live then host:showInfo(_(message or 'Could not load this book’s chapter list. Check your connection and login, then try again.')) end
    end
    host:showBusy(_('Loading chapter list...'),function() M.cancel(host) end)
    ctx.busy=host.busy_message
    if not host._catalog_request_worker then
        local made,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UIManager,codec=host.client,max_bytes=8*1024*1024} end)
        if not made then fail();return false end
        host._catalog_request_worker=worker
    end
    local launch,recover
    recover=function()
        if not current() or WorkerSettings.fingerprint(host.settings)~=ctx.fingerprint then M.cancel(host);return end
        if ctx.attempted then fail('WeRead login expired. Please sign in again and retry.');return end
        ctx.attempted=true
        local Renewal=require('weread.ui.web_renewal')
        local called,started,request=pcall(Renewal.run,host,{is_current=function()
            return current() and (not host.isNetworkOnline or host:isNetworkOnline())
        end},function(ok,receipt)
            if host._catalog_request~=ctx then return end
            ctx.request=nil
            if not current() or receipt=='session_changed' then M.cancel(host);return end
            if not ok then fail(Renewal.error_text(receipt));return end
            local verified,fresh=pcall(require('weread.lib.web_authorization').capture,host.settings)
            if not verified or type(receipt)~='table' or type(receipt.revision)~='string'
                or #receipt.revision~=64 or not receipt.revision:match('^[0-9a-f]+$')
                or type(fresh)~='table' or fresh.revision~=receipt.revision or type(fresh.scope)~='table'
                or fresh.scope.vid~=scope.vid or fresh.scope.epoch~=scope.epoch
                or not Source.web_access(host.settings) then M.cancel(host);return end
            ctx.fingerprint=WorkerSettings.fingerprint(host.settings)
            launch()
        end)
        if host._catalog_request==ctx then
            if called and started then ctx.request=request else fail() end
        elseif called and started and request then Renewal.cancel(host,request) end
    end
    launch=function()
        ctx.generation=(ctx.generation or 0)+1
        local generation=ctx.generation
        local ok,started=pcall(host._catalog_request_worker.start,host._catalog_request_worker,function()
            local good,value=pcall(function()
                local auth_result=WorkerSettings.capture(host.settings)
                local copy={book_id=id,title=book.title,author=book.author,reader_url=book.reader_url}
                local client=require('weread.lib.book_reading_client').wrap(host.client,copy)
                Content.ensure_reader_state(client,copy)
                local chapters=Content.fetch_catalog(client,copy)
                if not valid_catalog(chapters) then error('invalid_catalog',0) end
                return {book_id=id,chapters=chapters,auth=auth_result()}
            end)
            if good then return value end
            return {error=value=='book_reading/web_expired' and 'web_expired'
                or value=='download_read/rate_limited' and 'rate_limited' or 'unavailable'}
        end,function(result)
            if host._catalog_request~=ctx or ctx.generation~=generation then return end
            if not current() or WorkerSettings.fingerprint(host.settings)~=ctx.fingerprint then M.cancel(host);return end
            if type(result)=='table' and result.error=='web_expired' then recover();return end
            if type(result)=='table' and result.error=='rate_limited' then
                fail('WeRead is limiting requests. Download stopped. Please try again later.');return
            end
            if type(result)~='table' or result.book_id~=id or not valid_catalog(result.chapters) then fail();return end
            if result.auth and not WorkerSettings.merge(host.settings,ctx.fingerprint,result.auth) then fail();return end
            local chapters=result.chapters
            M.cancel(host)
            if not pcall(callback,chapters) then
                host:showInfo(_('Could not load this book’s chapter list. Check your connection and login, then try again.'))
            end
        end)
        if not ok or not started then fail();return false end
        return true
    end
    return launch()
end

return M
