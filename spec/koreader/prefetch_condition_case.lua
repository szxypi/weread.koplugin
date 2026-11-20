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
    if kind=='account' or kind=='auth-race' or kind=='before-commit' or kind=='suspend' then
        local lfs=require('libs/libkoreader-lfs')
        local dir=assert(reader.document.file:match('^(.*)/[^/]+$'))
        local function epubs()
            local names={}
            for name in lfs.dir(dir) do if name:match('%.epub$') then names[#names+1]=name end end
            table.sort(names);return table.concat(names,'\n')
        end
        local Content=require('weread.lib.content')
        local old_save,sentinel
        local ready_marker=evidence..'/prefetch-before-commit.ready'
        local release_marker=evidence..'/prefetch-before-commit.release'
        if kind=='before-commit' then
            local chapters=assert(host:ensureChaptersLoaded(book))
            local name=tostring((book.title or 'WeRead')..' - '..(chapters[3].title or tostring(chapters[3].chapterUid)))
                :gsub('[%z%c/\\:%*%?"<>|]','_'):gsub('^%s+',''):gsub('%s+$',''):gsub('%s+',' ')
            sentinel=dir..'/'..name..'.epub'
            local existing=io.open(sentinel,'rb');assert(not existing,'synthetic destination already exists')
            local file=assert(io.open(sentinel,'wb'));file:write('prior-synthetic-chapter');file:close()
            old_save=Content.save_chapter_epub
            Content.save_chapter_epub=function(a,b,c,d,e,f,g,h,i,guard)
                local function held()
                    local ready=assert(io.open(ready_marker,'wb'));ready:write('ready');ready:close()
                    local until_time=socket.gettime()+20
                    while socket.gettime()<until_time do
                        local released=io.open(release_marker,'rb')
                        if released then released:close();return guard() end
                        socket.sleep(.01)
                    end
                    error('prefetch fixture release timeout',0)
                end
                return old_save(a,b,c,d,e,f,g,h,i,held)
            end
        end
        local before=epubs()
        request('/__control',{match='/web/book/chapter/e_0',times=0,delay=1})
        assert(host:maybePrefetchNextChapter(id),'lifecycle prefetch did not start')
        pump(function()
            if kind=='before-commit' then
                local ready=io.open(ready_marker,'rb');if ready then ready:close();return true end
            else
                for url in pairs(request('/__state').active_requests) do
                    if url:find('/web/book/chapter/e_0',1,true) then return true end
                end
            end
        end)
        if old_save then Content.save_chapter_epub=old_save end
        local old_epoch=settings:get('auth_epoch',0)
        if kind=='suspend' then host:onSuspend()
        else
            settings:set('auth_epoch',old_epoch+1);settings:flush()
            if kind=='account' then host:onWeReadAccountChanged() end
        end
        if kind=='before-commit' then local release=assert(io.open(release_marker,'wb'));release:write('go');release:close() end
        pump(function() return not host.downloader._active_job end)
        assert(Reader.instance==reader and epubs()==before,'stale prefetch changed an EPUB or opened a reader')
        if sentinel then
            local file=assert(io.open(sentinel,'rb'));local text=file:read('*a');file:close()
            assert(text=='prior-synthetic-chapter' and not io.open(sentinel..'.part','rb'),'stale publication replaced the existing file')
            assert(os.remove(sentinel))
        end
        local saved=assert(settings:get_book(id))
        assert(not saved.cached_chapters or not saved.cached_chapters['3'],'stale prefetch was stored in the new session')
        request('/__control',{match='',times=0,delay=0})
        if kind=='suspend' then
            assert(host._resume_chapter_prefetch,'suspend did not retain a wake intent')
            host:onResume()
            pump(function()
                local current=settings:get_book(id)
                return current and current.cached_chapters and current.cached_chapters['3'] and not host.downloader._active_job
            end)
        else
            settings:set('auth_epoch',old_epoch);settings:flush()
            if kind=='account' then host:onWeReadAccountChanged() end
        end
        cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
        host.showInfo=old_info
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        local file=assert(io.open(evidence..'/prefetch-condition.json','wb'))
        file:write(Json.encode{result='PASS',scenario=kind,old_epub_preserved=true,stale_not_cached=true,
            resumed=kind=='suspend',renewals=count('/web/login/renewal')-renewals});file:close()
        return reader,host
    end
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
