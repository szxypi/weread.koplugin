-- Cancellable native MP directory refresh; one read, no automatic renewal/replay.
local Model=require('weread.lib.mp_catalog')
local Content=require('weread.lib.content')
local UIManager=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function scope(host)
    return {account=host.library_db and host.library_db:accountKey(),epoch=host.discovery_epoch or 0,
        document=host.ui and host.ui.document,file=host.ui and host.ui.document and host.ui.document.file,
        session=host._reader_session_gen,cache=host.settings.cache_dir}
end
local function current(host,owner,input)
    return owner.account==(host.library_db and host.library_db:accountKey()) and owner.epoch==(host.discovery_epoch or 0)
        and owner.document==(host.ui and host.ui.document) and owner.file==(host.ui and host.ui.document and host.ui.document.file)
        and owner.session==host._reader_session_gen and owner.cache==host.settings.cache_dir and Model.matches(host.settings,input)
end
function M.cancel(host)
    local job=host.mp_catalog_job;host.mp_catalog_job=nil
    if not job then return end
    if host.mp_catalog_worker then host.mp_catalog_worker:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function restore(host,book)
    local cached=host:getCachedMPArticles(book.book_id)
    if type(cached)=='table' then host:showMPArticleList(book,cached) end
end
local function failed(host,book,kind)
    restore(host,book)
    host:showInfo(kind=='verification' and _('Public-account verification is temporarily unavailable. Cached articles can still be read. Please try again later.')
        or kind=='login' and _('WeRead could not refresh the public-account credential. Please scan the QR code again.')
        or _('Could not refresh the article list. Saved articles are kept. Please check the network and try again.'))
end
function M.start(host,book)
    if not host:requireLogin(true,false) then return false end
    if not host:isNetworkConnected() then host:showOffline(_('Refresh article list'));return false end
    host:closeWeReadUI()
    local owner=scope(host)
    local captured,input=pcall(Model.capture,host.settings,book)
    if not captured or not input then
        host:showInfo(_('Could not read the public-account credential. Please check your login.'));return false
    end
    local selected={book_id=input.book_id,title=type(book.title)=='string' and book.title or _('Public Account'),
        author=book.author,cache_dir=Content.book_resolved_dir(host.settings,input.book_id,book)}
    local job={owner=owner,input=input,book=selected,started=os.time()};host.mp_catalog_job=job
    host:showBusy(_('Loading articles…\nTap or press a key to cancel.'),function() if host.mp_catalog_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    local function stop(kind)
        M.cancel(host);failed(host,selected,kind)
    end
    if not host.mp_catalog_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=Model.MAX_RESULT} end)
        if not ok then stop();return false end;host.mp_catalog_worker=worker
    end
    local ok,started=pcall(host.mp_catalog_worker.start,host.mp_catalog_worker,function() return Model.read(host.client,input) end,function(result)
        if host.mp_catalog_job~=job then return end
        local age=os.time()-job.started
        if not current(host,owner,input) or age<0 or age>120 then M.cancel(host);return end
        local latest=host.settings:get('books',{})[input.book_id]
        if type(latest)=='table' and latest.cache_dir and latest.cache_dir~='' and latest.cache_dir~=selected.cache_dir then M.cancel(host);return end
        if type(result)~='table' or result.ok~=true then stop(type(result)=='table' and result.kind);return end
        local valid,articles=pcall(Model.rows,result.articles,input.book_id)
        if not valid then stop();return end
        M.cancel(host)
        -- cacheMPArticles re-reads the latest record instead of replacing it with
        -- the pre-request book, so concurrent progress and pending intent survive.
        local saved=pcall(host.cacheMPArticles,host,input.book_id,articles)
        if not saved then
            restore(host,selected)
            host:showInfo(_('Could not save the refreshed article list. Please check available storage.'));return
        end
        host:showMPArticleList(selected,articles)
    end)
    if not ok or not started then stop();return false end
    return true
end
return M
