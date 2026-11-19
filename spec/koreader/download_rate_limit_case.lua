-- Inject a rate-limited or expired chapter into a background full-book download.
return function(host, view, book, pump, tick, press)
    local UI = require('ui/uimanager')
    local Json, HTTP, LTN = require('json'), require('socket.http'), require('ltn12')
    local Content = require('weread.lib.content')
    local function request(path, data)
        local chunks, raw = {}, data and Json.encode(data)
        local _, code = HTTP.request{url=host.settings.mock_endpoint..path,proxy=host.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local total=0
        for _,row in ipairs(request('/__state').totals) do if row.path==path then total=total+row.count end end
        return total
    end
    local path='/web/book/chapter/'..(os.getenv('WEREAD_TEST_CONTENT_FORMAT')=='txt' and 't_0' or 'e_0')
    local before=count(path)
    local expired=os.getenv('WEREAD_TEST_DOWNLOAD_AUTH_EXPIRY')=='1'
    request('/__control',{match=path,times=-1,skip=1,status=expired and 401 or 429})
    local notice, old_info = nil, host.downloader.show_info
    host.downloader.show_info=function(text) notice=text;return old_info(text) end
    local recovery=require('weread.ui.download_recovery')
    local old_start=recovery.start
    if expired then recovery.start=function(target,...)
        recovery.start=old_start
        return target.downloader:start(...)
    end end
    press(view,'⇩ Download full book')
    local job
    pump(function() job=host.downloader._active_job;return job~=nil end)
    pump(function() return not host.downloader._active_job end)
    host.downloader.show_info=old_info
    local expected=expired and 'WeRead login expired. Download paused; completed chapters are kept. Sign in again and choose Download full book to resume.'
        or 'WeRead is limiting requests. Download paused; completed chapters are kept. Try Download full book again later.'
    assert(notice==require('weread.lib.i18n').tr(expected))
    assert(count(path)-before==2, 'paused download retried or read another chapter')
    assert(job.workspace and not host.downloader._standby_token)
    local saved=Content.full_download_completed_chapters(job.workspace,job.chapters,job.source_identity.book_version)
    assert(saved[1] and not saved[2], 'completed chapter was not retained')
    assert(not book(host).cached_full_book, 'partial book was published')
    request('/__control',{match='',times=0,skip=0})
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=view do UI:close(UI:getTopmostVisibleWidget()) end
    tick();press(view,'⇩ Download full book')
    return function()
        assert(count(path)-before==7, 'resume redownloaded a completed chapter or skipped a remaining chapter')
        return {reason=expired and 'login_expired' or 'rate_limited',limited_after_one=true,no_automatic_retry=true,checkpoint_reused=true,complete_book_only=true}
    end
end
