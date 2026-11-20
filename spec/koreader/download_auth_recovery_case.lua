-- Exercise the actual full-download UI and a synthetic one-time Web renewal.
return function(host,view,book,pump,tick,press)
    local UI=require('ui/uimanager')
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local kind=assert(os.getenv('WEREAD_TEST_DOWNLOAD_AUTH_RENEWAL'))
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=host.settings.mock_endpoint..path,proxy=host.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local total=0
        for _,row in ipairs(request('/__state').totals) do if row.path==path then total=total+row.count end end
        return total
    end
    local shard='/web/book/chapter/'..(os.getenv('WEREAD_TEST_CONTENT_FORMAT')=='txt' and 't_0' or 'e_0')
    local before=count(shard)
    local before_renewal=count('/web/login/renewal')
    local path=kind=='reader' and '/web/reader/' or shard
    request('/__control',{match=path,times=kind=='repeat401' and -1 or 1,
        skip=kind=='reader' and 0 or 1,status=401,web_renewal_mode='rotate'})
    local old_info,notice=host.showInfo,nil
    host.showInfo=function(self,text,...) notice=text;print('DOWNLOAD_AUTH_NOTICE: '..tostring(text));return old_info(self,text,...) end
    press(view,'⇩ Download full book')
    if kind=='repeat401' then
        pump(function() return notice~=nil end)
        assert(notice==require('weread.lib.i18n').tr('WeRead login expired. Download paused; completed chapters are kept. Sign in again and choose Download full book to resume.'))
        assert(count('/web/login/renewal')==before_renewal+1,'second 401 triggered another renewal')
        assert(count(shard)-before==3,'second 401 retried or skipped a chapter')
        assert(not book(host).cached_full_book,'incomplete full book was published')
        request('/__control',{match='',times=0,skip=0})
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=view do UI:close(UI:getTopmostVisibleWidget()) end
        tick();press(view,'⇩ Download full book')
    end
    return function()
        host.showInfo=old_info
        assert(count('/web/login/renewal')==before_renewal+1,'full download did not renew exactly once')
        local expected=kind=='reader' and 6 or kind=='chapter' and 7 or 8
        assert(count(shard)-before==expected,'download repeated a completed chapter or skipped a source')
        local access=assert(require('weread.lib.web_authorization').capture(host.settings))
        assert(access.scope.vid==host.settings:get_auth_scope().vid)
        return {stage=kind,renewals=1,completed_chapters_reused=kind~='reader',
            complete_book_only=true,same_account=true,offline_reopen=true}
    end
end
