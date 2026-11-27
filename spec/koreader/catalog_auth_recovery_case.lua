-- Force an uncached catalog through the actual plugin entry and mock HTTP.
return function(host,view,book,pump,tick,press)
    local UI=require('ui/uimanager')
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local kind=assert(os.getenv('WEREAD_TEST_CATALOG_AUTH_RECOVERY'))
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
    local saved=book(host);local id=assert(saved.book_id or saved.bookId)
    if kind=='refresh' then
        host:showChapterList(saved)
        local original=assert(host._chapter_list_view)
        local title=assert(original._chapter_rows[1]).text
        UI:forceRePaint()
        assert(original._toolbar_buttons[3]):onTapSelectButton()
        local search=assert(original._shelf_popup);search:setInputText(title);search.buttons[1][2].callback()
        original=assert(host._chapter_list_view)
        assert(#original._chapter_rows==1 and original.subtitle)
        local before=count('/web/login/renewal')
        request('/__control',{match='/web/book/chapterInfos',times=1,status=401,web_renewal_mode='rotate'})
        local store=host.settings
        local get,set=store.get,store.set
        store.get=function(self,key,...)
            assert(key~='books','one catalog refresh hydrated the bookshelf')
            return get(self,key,...)
        end
        store.set=function(self,key,...)
            assert(key~='books','one catalog refresh rewrote the bookshelf')
            return set(self,key,...)
        end
        original._toolbar_buttons[1].callback()
        pump(function() return host._catalog_request and host._catalog_request_worker.job end)
        local last_pull=saved.last_pull_at
        local checkpoint=(last_pull or 0)+123
        assert(store:patch_reading_state(id,{last_pull_at=checkpoint}))
        pump(function() return host._chapter_list_view and host._chapter_list_view~=original end)
        store.get,store.set=get,set
        local updated=book(host)
        assert(updated.last_pull_at==checkpoint and #assert(host.library_db:getChapters(id))==6,
            'refresh lost an updated checkpoint or failed to persist the catalog')
        for uid,path in pairs(saved.cached_chapters or {}) do assert(updated.cached_chapters[uid]==path) end
        assert(store:patch_reading_state(id,{last_pull_at=last_pull or false}))
        local refreshed=host._chapter_list_view
        assert(#refreshed._chapter_rows==1 and refreshed._chapter_rows[1].text==title
            and refreshed.subtitle==original.subtitle and count('/web/login/renewal')==before+1)
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=refreshed do UI:close(UI:getTopmostVisibleWidget()) end
        refreshed:onClose();pump(function() return host._chapter_list_view==nil end)
        press(view,'⇩ Download full book')
        return function()
            assert(count('/web/login/renewal')==before+1)
            return {stage=kind,renewals=1,background=true,catalog_saved=true,complete_book_only=true,offline_reopen=true}
        end
    end
    saved.chapters=nil
    local books=host.settings:get('books',{});books[id]=saved;host.settings:set('books',books);host.settings:flush()
    assert(host.library_db:putChapters(id,{}))
    os.remove(assert(require('weread.lib.content').catalog_cache_path(host.settings,saved)))
    assert(not host.library_db:getChapters(id))
    local renewal=count('/web/login/renewal')
    local catalog=count('/web/book/chapterInfos')
    local target=kind=='reader' and '/web/reader/' or '/web/book/chapterInfos'
    request('/__control',{match=target,times=(kind=='repeat401' or kind=='limited') and -1 or 1,
        status=kind=='limited' and 429 or 401,web_renewal_mode='rotate'})
    local old_info,notice=host.showInfo,nil
    host.showInfo=function(self,text,...) notice=text;return old_info(self,text,...) end
    press(view,'⇩ Download full book')
    local worker_seen=false
    pump(function()
        if host._catalog_request then worker_seen=host._catalog_request_worker and host._catalog_request_worker.job~=nil;return true end
        return notice~=nil
    end)
    assert(worker_seen,'uncached catalog did not use a background worker')
    if kind=='repeat401' or kind=='limited' then
        pump(function() return notice~=nil end)
        local expected=kind=='limited' and 'WeRead is limiting requests. Download stopped. Please try again later.'
            or 'WeRead login expired. Please sign in again and retry.'
        assert(notice==require('weread.lib.i18n').tr(expected))
        assert(count('/web/login/renewal')==renewal+(kind=='limited' and 0 or 1))
        assert(not host.library_db:getChapters(id) and not book(host).cached_full_book,'failed catalog modified the cache or published a book')
        request('/__control',{match='',times=0})
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=view do UI:close(UI:getTopmostVisibleWidget()) end
        tick();press(view,'⇩ Download full book')
    end
    return function()
        host.showInfo=old_info
        assert(count('/web/login/renewal')==renewal+(kind=='limited' and 0 or 1),'catalog renewal count changed')
        assert(count('/web/book/chapterInfos')>=catalog+1 and #assert(host.library_db:getChapters(id))==6)
        return {stage=kind,renewals=kind=='limited' and 0 or 1,background=true,
            catalog_saved=true,complete_book_only=true,offline_reopen=true}
    end
end
