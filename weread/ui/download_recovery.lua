-- Resume a confirmed full-book download after one verified Web renewal.
local UIManager = require('ui/uimanager')
local Content = require('weread.lib.content')
local Access = require('weread.lib.read_access')
local FileIdentity = require('weread.lib.book_file_identity')
local Source = require('weread.lib.shelf_source')
local WorkerSettings = require('weread.lib.worker_settings')
local Reading = require('weread.ui.book_reading')
local Scope = require('weread.ui.page_scope')
local _ = require('weread.lib.plugin_util').tr
local M = {}

local function same_catalog(left,right)
    if not left or not right or #left~=#right then return false end
    for i,row in ipairs(left) do
        local other=right[i]
        for _,key in ipairs({'chapterUid','title','chapterIdx','wordCount','level'}) do
            if row[key]~=other[key] then return false end
        end
    end
    return true
end

function M.cancel(host,leave_download)
    local ctx=host._full_download_recovery
    if not ctx then return end
    host._full_download_recovery=nil
    if ctx.schedule and UIManager.unschedule then UIManager:unschedule(ctx.schedule) end
    if host._full_download_recovery_worker then host._full_download_recovery_worker:cancel() end
    if ctx.request then require('weread.ui.web_renewal').cancel(host,ctx.request) end
    if ctx.complete and not leave_download then host.downloader:cancelRequest(ctx.complete,'download_cancelled') end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end

function M.start(host,book,chapters,suffix,options)
    options=options or {}
    if host._full_download_recovery then
        host:showTransientInfo(_('Another download is already in progress.'),1)
        return false
    end
    local id=Access.display_book_id(book.book_id or book.bookId)
    local catalog=Reading.catalog(chapters)
    local scope=host.settings:get_auth_scope()
    if not id or not catalog or not scope or not Source.web_access(host.settings) then
        return host.downloader:start(book,chapters,suffix,options)
    end
    local targets={}
    for i,row in ipairs(chapters) do
        local copy={};for key,value in pairs(row) do copy[key]=value end
        targets[i]=copy
    end
    local page_current=Scope.capture(host,host.shelf_view)
    local ctx={scope=scope,catalog=catalog,version=FileIdentity.version(book.bookVersion),
        fingerprint=WorkerSettings.fingerprint(host.settings),api_key=host.settings:get('api_key','')}
    host._full_download_recovery=ctx
    local function current()
        local valid,current_id=pcall(require('weread.lib.reader_context').book_id,book)
        return valid and current_id==id and host._full_download_recovery==ctx and page_current()
            and host.settings:auth_scope_matches(ctx.scope) and host.settings:get('api_key','')==ctx.api_key
    end
    local function finish(ok,value,message)
        if host._full_download_recovery~=ctx then return end
        local valid=current()
        M.cancel(host,true)
        if valid and type(options.on_complete)=='function' then pcall(options.on_complete,ok,value) end
        if valid and message then host:showInfo(_(message)) end
    end
    local launch,recover
    local download_book=book
    local function recheck()
        if not current() or WorkerSettings.fingerprint(host.settings)~=ctx.fingerprint then M.cancel(host);return end
        local ok,started=pcall(host._full_download_recovery_worker.start,host._full_download_recovery_worker,function()
            local good,value=pcall(function()
                local auth_result=WorkerSettings.capture(host.settings)
                local copy={book_id=id,title=book.title,author=book.author,reader_url=book.reader_url}
                local client=require('weread.lib.book_reading_client').wrap(host.client,copy)
                Content.ensure_reader_state(client,copy)
                local fresh,version=Content.fetch_catalog(client,copy)
                return {book_id=id,chapters=Reading.catalog(fresh),version=version or 0,auth=auth_result()}
            end)
            if good then return value end
            return {error=value=='book_reading/web_expired' and 'web_expired'
                or value=='download_read/rate_limited' and 'rate_limited' or 'unavailable'}
        end,function(result)
            if host._full_download_recovery~=ctx then return end
            if not current() or WorkerSettings.fingerprint(host.settings)~=ctx.fingerprint then M.cancel(host);return end
            if type(result)=='table' and result.error=='web_expired' then
                finish(false,'web_expired','WeRead login expired. Download paused; completed chapters are kept. Sign in again and choose Download full book to resume.');return
            end
            if type(result)=='table' and result.error=='rate_limited' then
                finish(false,'rate_limited','WeRead is limiting requests. Download paused; completed chapters are kept. Try Download full book again later.');return
            end
            local version=type(result)=='table' and result.version
            if type(result)~='table' or result.book_id~=id or not same_catalog(ctx.catalog,Reading.catalog(result.chapters))
                or type(version)~='number' or version%1~=0 or version<0 or version>2147483647
                or ctx.version>0 and version>0 and ctx.version~=version or FileIdentity.version(book.bookVersion)~=ctx.version then
                finish(false,'catalog_changed','Could not verify the book catalog. Download paused; completed chapters are kept. Try Download full book again.');return
            end
            if result.auth and not WorkerSettings.merge(host.settings,ctx.fingerprint,result.auth) then
                finish(false,'session_changed');return
            end
            ctx.fingerprint=WorkerSettings.fingerprint(host.settings)
            if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
            ctx.busy=nil
            -- Unknown old versions do not authorize reuse under a newly known
            -- version. If the fresh version is unavailable, preserve the
            -- existing resumable behavior but mark the new source as unknown.
            download_book={};for key,value in pairs(book) do download_book[key]=value end
            download_book.bookVersion=version
            launch()
        end)
        if not ok or not started then finish(false,'unavailable','Could not verify the book catalog. Download paused; completed chapters are kept. Try Download full book again.') end
    end
    recover=function()
        ctx.schedule=nil
        if not current() or WorkerSettings.fingerprint(host.settings)~=ctx.fingerprint then M.cancel(host);return end
        if ctx.attempted then
            finish(false,'web_expired','WeRead login expired. Download paused; completed chapters are kept. Sign in again and choose Download full book to resume.');return
        end
        ctx.attempted=true
        host:showBusy(_('Renewing WeRead login…\nTap or press a key to cancel.'),function() M.cancel(host) end)
        ctx.busy=host.busy_message
        local Renewal=require('weread.ui.web_renewal')
        local called,started,request=pcall(Renewal.run,host,{is_current=function()
            return current() and (not host.isNetworkOnline or host:isNetworkOnline())
        end},function(ok,receipt)
            if host._full_download_recovery~=ctx then return end
            ctx.request=nil
            if not current() or receipt=='session_changed' then M.cancel(host);return end
            if not ok then finish(false,receipt,Renewal.error_text(receipt));return end
            local verified,fresh=pcall(require('weread.lib.web_authorization').capture,host.settings)
            if not verified or type(receipt)~='table' or type(receipt.revision)~='string'
                or #receipt.revision~=64 or not receipt.revision:match('^[0-9a-f]+$')
                or type(fresh)~='table' or fresh.revision~=receipt.revision or type(fresh.scope)~='table'
                or fresh.scope.vid~=ctx.scope.vid or fresh.scope.epoch~=ctx.scope.epoch
                or not Source.web_access(host.settings) then M.cancel(host);return end
            ctx.fingerprint=WorkerSettings.fingerprint(host.settings)
            if not host._full_download_recovery_worker then
                local made,worker=pcall(function() return require('weread.lib.memory_worker'):new{
                    scheduler=UIManager,codec=host.client,max_bytes=4*1024*1024} end)
                if not made then finish(false,'unavailable');return end
                host._full_download_recovery_worker=worker
            end
            recheck()
        end)
        if host._full_download_recovery==ctx then
            if called and started then ctx.request=request
            else finish(false,'unavailable',Renewal.error_text('unavailable')) end
        elseif called and started and request then Renewal.cancel(host,request) end
    end
    ctx.complete=function(ok,value)
        if host._full_download_recovery~=ctx then return end
        if not current() or WorkerSettings.fingerprint(host.settings)~=ctx.fingerprint then M.cancel(host);return end
        if not ok and value=='web_expired' then
            ctx.schedule=function() if host._full_download_recovery==ctx then recover() end end
            UIManager:scheduleIn(0.1,ctx.schedule)
        else finish(ok,value) end
    end
    launch=function()
        local copy={};for key,value in pairs(options) do copy[key]=value end
        copy.full_auth_recovery=true;copy.on_complete=ctx.complete
        copy.on_reading_auth_updated=function(before,after)
            if current() and ctx.fingerprint==before and Source.web_access(host.settings) then ctx.fingerprint=after end
        end
        local ok,started=pcall(host.downloader.start,host.downloader,download_book,targets,suffix,copy)
        if not ok or not started then finish(false,'unavailable') end
        return ok and started
    end
    return launch()
end

return M
