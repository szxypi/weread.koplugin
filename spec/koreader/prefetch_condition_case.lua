-- Real ReaderUI and prefetch subprocess, isolated synthetic HTTP only.
return function(reader,host,book,id,evidence)
    local UI=require('ui/uimanager')
    local socket,Json,HTTP,LTN=require('socket'),require('json'),require('socket.http'),require('ltn12')
    local tr=require('weread.lib.plugin_util').tr
    local kind=assert(os.getenv('WEREAD_TEST_PREFETCH_CONDITION'))
    local first=reader.document.file
    local Reader=require('apps/reader/readerui')
    local function request(path,data)
        local chunks,body={},data and Json.encode(data)
        local _,code=HTTP.request{url=host.settings.mock_endpoint..path,proxy=host.settings.mock_endpoint,
            method=body and 'POST' or 'GET',source=body and LTN.source.string(body),
            headers=body and {['Content-Type']='application/json',['Content-Length']=tostring(#body)} or {},
            sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function count(path)
        local total=0
        for _,row in ipairs(request('/__state').totals) do if row.path==path then total=total+row.count end end
        return total
    end
    local function pump(condition)
        local deadline=socket.gettime()+35
        repeat
            UI:handleInput()
            if condition() then return end
            assert(socket.gettime()<deadline,'prefetch condition timed out')
            socket.sleep(.01)
        until false
    end
    local settings=host.settings
    local cache=settings:get('cache',{})
    cache.auto_prefetch_next_chapter=true;cache.show_prefetch_notifications=false
    settings:set('cache',cache);settings:flush()
    local shards=count('/web/book/chapter/e_0')
    local renewals=count('/web/login/renewal')
    local notice,old_info=nil,host.showInfo
    host.showInfo=function(self,text,...) notice=text;return old_info(self,text,...) end
    local succeeds=kind=='stale' or kind=='promoted-success'
    request('/__control',{match='/web/book/chapter/e_0',times=succeeds and 0 or -1,
        status=kind=='rate' and 429 or 401,delay=succeeds and 0.7 or 0})
    assert(host:maybePrefetchNextChapter(id),'next chapter prefetch did not start')
    local active=assert(host.downloader:getActivePrefetch())
    local view
    if kind~='expired' then
        host:showChapterList(book);view=assert(host._chapter_list_view)
        view._chapter_rows[3].callback()
        assert(active.promoted and active.promotion_current and active.promotion_current(),'chapter selection did not promote current prefetch')
        if kind=='stale' then UI:close(view);assert(not active.promotion_current(),'closed chapter list retained the selection') end
    end
    pump(function() return not host.downloader._active_job end)
    assert(count('/web/book/chapter/e_0')-shards==1,'prefetch repeated the first chapter request')
    assert(count('/web/login/renewal')==renewals,'background prefetch attempted login renewal')
    if kind=='promoted-success' then
        pump(function() return Reader.instance and Reader.instance~=reader end)
        local selected_reader=Reader.instance
        assert(selected_reader.weread.settings:get_book(id).cached_chapters['3']==selected_reader.document.file,
            'current promoted prefetch did not open its selected chapter')
        local saved=assert(selected_reader.weread.settings:get_book(id))
        selected_reader.weread:openChapter(saved,{chapterUid=2})
        pump(function() return Reader.instance and Reader.instance~=selected_reader and Reader.instance.document.file==first end)
        reader,host=Reader.instance,Reader.instance.weread
        settings=host.settings;cache=settings:get('cache',{})
    else
        assert(Reader.instance==reader,'prefetch opened an unexpected chapter')
    end
    if kind=='promoted-expired' or kind=='promoted-recovery' then
        pump(function()
            local top=UI:getTopmostVisibleWidget()
            return top and top.ok_text==tr('Download') and top.ok_callback
        end)
        local top=UI:getTopmostVisibleWidget();UI:close(top)
        if kind=='promoted-recovery' then
            request('/__control',{match='/web/book/chapter/e_0',times=1,status=401,delay=0,web_renewal_mode='rotate'})
            top.ok_callback()
            pump(function() return host._full_download_recovery and host._full_download_recovery.attempted end)
            request('/__control',{match='',times=0,delay=0})
            pump(function()
                local read=UI:getTopmostVisibleWidget()
                if read and read.ok_text==tr('Read now') and read.ok_callback then UI:close(read);read.ok_callback() end
                return Reader.instance and Reader.instance~=reader
            end)
            assert(count('/web/login/renewal')==renewals+1,'selected prefetch did not recover expired login once')
            local selected_reader=Reader.instance
            local saved=assert(selected_reader.weread.settings:get_book(id))
            assert(saved.cached_chapters['3']==selected_reader.document.file,'selected recovered chapter was not opened')
            selected_reader.weread:openChapter(saved,{chapterUid=2})
            pump(function() return Reader.instance and Reader.instance~=selected_reader and Reader.instance.document.file==first end)
            reader,host=Reader.instance,Reader.instance.weread
            settings=host.settings;cache=settings:get('cache',{})
        end
    elseif kind=='rate' then
        assert(notice==tr('WeRead is limiting requests. Download stopped. Please try again later.'),
            'selected rate-limited chapter did not explain the failure')
    elseif kind=='stale' then
        local stored=assert(settings:get_book(id))
        assert(stored.cached_chapters and stored.cached_chapters['3'],'stale selection lost the completed cache')
    end
    request('/__control',{match='',times=0,delay=0})
    cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
    if kind~='promoted-success' and kind~='promoted-recovery' then host.showInfo=old_info end
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    local file=assert(io.open(evidence..'/prefetch-condition.json','wb'))
    file:write(Json.encode{result='PASS',scenario=kind,chapter_requests=1,renewals=0,foreground_renewals=kind=='promoted-recovery' and 1 or 0,
        stale_did_not_open=kind=='stale',rate_message=kind=='rate',promoted_confirmation=kind=='promoted-expired' or kind=='promoted-recovery',
        promoted_opened=kind=='promoted-success' or kind=='promoted-recovery',foreground_recovery=kind=='promoted-recovery'});file:close()
    return reader,host
end
