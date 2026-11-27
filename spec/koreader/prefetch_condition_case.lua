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
    if kind=='identity-change' then
        request('/__control',{match='/web/book/chapter/e_0',times=0,delay=.7})
        local apply=host.downloader._applyPrefetchResult
        host.downloader._applyPrefetchResult=function(self,job,result)
            self._applyPrefetchResult=apply
            if result.ok then job.book.book_id='900002' end
            return apply(self,job,result)
        end
        assert(host:maybePrefetchNextChapter(id),'changed-identity prefetch did not start')
        local active=assert(host.downloader:getActivePrefetch())
        host:showChapterList(book);local view=assert(host._chapter_list_view);view._chapter_rows[3].callback()
        assert(active.promoted and active.promotion_current and active.promotion_current(),
            'changed-identity test did not promote the background task')
        pump(function() return not host.downloader._active_job end)
        assert(notice==tr('Saved book information does not match. The chapter was not linked; refresh the book and check its cache.'),
            'changed book identity did not show the protected-cache notice')
        local saved=assert(settings:get_book(id))
        assert(not saved.cached_chapters or not saved.cached_chapters['3'],
            'changed-identity prefetch was registered to the original book')
        local until_time=socket.gettime()+1.5
        while socket.gettime()<until_time do UI:handleInput();socket.sleep(.01) end
        assert(Reader.instance==reader and count('/web/book/chapter/e_0')-shards==1,
            'changed-identity prefetch retried or changed the open reader')
        request('/__control',{match='',times=0,delay=0})
        cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush();host.showInfo=old_info
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        local file=assert(io.open(evidence..'/prefetch-condition.json','wb'))
        file:write(Json.encode{result='PASS',scenario=kind,record_preserved=true,promoted_not_retried=true,chapter_requests=1});file:close()
        return reader,host
    end
    if kind=='identity-conflict' then
        request('/__control',{match='/web/book/chapter/e_0',times=0,delay=1})
        assert(host:maybePrefetchNextChapter(id),'conflict test prefetch did not start')
        local active=assert(host.downloader:getActivePrefetch())
        host:showChapterList(book);local view=assert(host._chapter_list_view);view._chapter_rows[3].callback()
        assert(active.promoted and active.promotion_current and active.promotion_current(),
            'conflict test did not promote the background task')
        pump(function()
            for url in pairs(request('/__state').active_requests) do
                if url:find('/web/book/chapter/e_0',1,true) then return true end
            end
        end)
        local get=settings.get;local original=get(settings,'books',{});local records={}
        for key,value in pairs(original) do records[key]=value end
        local foreign={};for key,value in pairs(assert(original[id])) do foreign[key]=value end
        foreign.book_id='900002';records[id]=foreign
        local get_book,get_indexes=settings.get_book,settings.get_book_indexes
        settings.get_book=function(self,requested,...)
            if requested==id then return foreign end
            return get_book(self,requested,...)
        end
        settings.get_book_indexes=function(self)
            local indexes={}
            for key,value in pairs(get_indexes(self)) do indexes[key]=value end
            indexes[id]={cache_dir=foreign.cache_dir,book_id=foreign.book_id}
            return indexes
        end
        settings.get=function(self,key,default)
            if key=='books' then return records end
            return get(self,key,default)
        end
        -- Inspect annotation ownership inside the real ReaderUI while the
        -- same conflicting cache snapshot is visible to the parent process.
        foreign.annotation_documents={[reader.document.file]={clean=true,chapters={}}}
        local old_binding,old_detect=host._annotationBinding,host.detectWeReadBook
        local old_context,old_active=host._annotation_context,host._unified_annotations_active
        local old_document=host.external_annotations_db.getDocument
        host.external_annotations_db.getDocument=function() return nil end
        host.detectWeReadBook=function() return id end
        assert(host:_annotationBinding()==nil,'reader accepted a conflicting automatic book binding')
        host._annotationBinding=function() return {book_id=id,automatic=true} end
        host._annotation_context=nil;host._unified_annotations_active=nil
        assert(not host:_usesUnifiedAnnotations(),'reader activated a conflicting annotation descriptor')
        local annotation=assert(host:_prepareAnnotationContext(false))
        assert(annotation.book==nil and annotation.descriptor==nil,'reader associated a conflicting annotation record')
        host._annotationBinding=old_binding;host.detectWeReadBook=old_detect
        host._annotation_context=old_context;host._unified_annotations_active=old_active
        host.external_annotations_db.getDocument=old_document
        pump(function() return not host.downloader._active_job end)
        settings.get=get
        settings.get_book,settings.get_book_indexes=get_book,get_indexes
        assert(notice==tr('Saved book information does not match. The chapter was not linked; refresh the book and check its cache.'),
            'conflicting identity did not show the protected-cache notice')
        local saved=assert(settings:get_book(id))
        assert(not saved.cached_chapters or not saved.cached_chapters['3'],
            'conflicting prefetch was registered to the original book')
        assert(not foreign.cached_chapters or not foreign.cached_chapters['3'],
            'conflicting prefetch changed the foreign record')
        local until_time=socket.gettime()+1.5
        while socket.gettime()<until_time do UI:handleInput();socket.sleep(.01) end
        assert(Reader.instance==reader and count('/web/book/chapter/e_0')-shards==1,
            'conflicting prefetch retried or changed the open reader')
        request('/__control',{match='',times=0,delay=0})
        cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush();host.showInfo=old_info
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        local file=assert(io.open(evidence..'/prefetch-condition.json','wb'))
        file:write(Json.encode{result='PASS',scenario=kind,record_preserved=true,promoted_not_retried=true,
            reader_annotation_not_bound=true,chapter_requests=1});file:close()
        return reader,host
    end
    if kind:match('^auto%-') then
        local target=kind=='auto-reader' and '/web/reader/'
            or kind=='auto-style' and '/web/book/chapter/e_2'
            or kind=='auto-txt' and '/web/book/chapter/t_0' or '/web/book/chapter/e_0'
        request('/__control',{match=target,times=kind=='auto-repeat' and -1 or 1,status=401,delay=0,web_renewal_mode='rotate'})
        assert(host:maybePrefetchNextChapter(id),'automatic renewal prefetch did not start')
        if kind=='auto-cancel' or kind=='auto-manual' then
            pump(function() return host._prefetch_auth_recovery and host._prefetch_auth_recovery.task end)
            request('/__control',{match='/web/login/renewal',times=0,delay=1})
            pump(function() return host._prefetch_auth_recovery and host._prefetch_auth_recovery.job end)
            if kind=='auto-manual' then
                host:showChapterList(book)
                local view=assert(host._chapter_list_view);view._chapter_rows[3].callback()
                local prompt=assert(UI:getTopmostVisibleWidget())
                assert(prompt.ok_text==tr('Download') and prompt.ok_callback,'manual selection did not open its download confirmation')
                UI:close(prompt);UI:close(view)
            else host:onSuspend() end
            assert(not host._prefetch_auth_recovery and (not host.web_renewal or not host.web_renewal.job),
                'suspend retained automatic renewal')
            local deadline=socket.gettime()+1.6
            while socket.gettime()<deadline do UI:handleInput();socket.sleep(.01) end
            assert(count('/web/login/renewal')-renewals<=1 and Reader.instance==reader,'cancelled renewal retried or opened a book')
            cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
            request('/__control',{match='',times=0,delay=0})
            if kind=='auto-cancel' then host:onResume() end
        elseif kind=='auto-changed' or kind=='auto-catalog-cancel' then
            pump(function() return host._prefetch_auth_recovery and host._prefetch_auth_recovery.task end)
            request('/__control',{match='/web/book/chapterInfos',times=0,delay=.7})
            local Content=require('weread.lib.content')
            local old_catalog=Content.fetch_catalog
            if kind=='auto-changed' then
                Content.fetch_catalog=function(...)
                    local chapters,version=old_catalog(...)
                    chapters[3].title=chapters[3].title..' changed'
                    return chapters,version
                end
            end
            pump(function()
                local owner=host._prefetch_auth_recovery
                return owner and owner.worker and owner.worker.job
            end)
            Content.fetch_catalog=old_catalog
            if kind=='auto-catalog-cancel' then
                host:onSuspend()
                assert(not host._prefetch_auth_recovery and not host._prefetch_auth_recovery_worker.job,
                    'suspend retained the catalog verification worker')
                cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
                request('/__control',{match='',times=0,delay=0});host:onResume()
            else
                pump(function() return not host._prefetch_auth_recovery and not host.downloader._active_job end)
            end
            local saved=assert(settings:get_book(id))
            assert(not saved.cached_chapters or not saved.cached_chapters['3'],'changed or cancelled catalog resumed prefetch')
            assert(count('/web/book/chapter/e_0')-shards==1 and count('/web/login/renewal')-renewals==1,
                'catalog change or cancellation unexpectedly retried the chapter')
        elseif kind=='auto-repeat' then
            pump(function()
                return count('/web/book/chapter/e_0')-shards>=2 and not host.downloader._active_job and not host._prefetch_auth_recovery
            end)
            local deadline=socket.gettime()+.7
            while socket.gettime()<deadline do UI:handleInput();socket.sleep(.01) end
            assert(count('/web/book/chapter/e_0')-shards==2 and count('/web/login/renewal')-renewals==1,
                'persistent expiry caused repeated background renewals')
        else
            pump(function()
                local saved=settings:get_book(id)
                return saved and saved.cached_chapters and saved.cached_chapters['3']
                    and not host.downloader._active_job and not host._prefetch_auth_recovery
            end)
            assert(count('/web/login/renewal')-renewals==1,'expired background read did not renew exactly once')
        end
        assert(Reader.instance==reader and not notice and not host.busy_message,'automatic renewal interrupted the reader')
        request('/__control',{match='',times=0,delay=0})
        cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush();host.showInfo=old_info
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        local file=assert(io.open(evidence..'/prefetch-condition.json','wb'))
        file:write(Json.encode{result='PASS',scenario=kind,renewals=count('/web/login/renewal')-renewals,
            reading_interrupted=false,automatic_retry=kind~='auto-cancel' and kind~='auto-manual' and kind~='auto-repeat'
                and kind~='auto-changed' and kind~='auto-catalog-cancel',
            cancelled=kind=='auto-cancel' or kind=='auto-catalog-cancel' or kind=='auto-manual',catalog_changed=kind=='auto-changed'});file:close()
        return reader,host
    end
    if kind=='account' or kind=='auth-race' or kind=='before-commit' or kind=='suspend' then
        local lfs=require('libs/libkoreader-lfs')
        local dir=assert(reader.document.file:match('^(.*)/[^/]+$'))
        local function epubs()
            local names={}
            for name in lfs.dir(dir) do if name:match('%.epub$') then names[#names+1]=name end end
            table.sort(names);return table.concat(names,'\n')
        end
        local Content=require('weread.lib.content')
        local old_save,sentinel,sentinel_bytes
        local ready_marker=evidence..'/prefetch-before-commit.ready'
        local release_marker=evidence..'/prefetch-before-commit.release'
        if kind=='before-commit' then
            local chapters=assert(host:ensureChaptersLoaded(book))
            local seed={};for key,value in pairs(book) do seed[key]=value end
            seed.cached_chapters={};seed.cache_dir=dir
            sentinel=Content.save_chapter_epub(settings,seed,chapters[3],'<p>prior synthetic chapter</p>',{},'',
                require('weread.lib.book_file_identity').capture(seed))
            local file=assert(io.open(sentinel,'rb'));sentinel_bytes=file:read('*a');file:close()
            assert(require('weread.lib.chapter_cache_path').plan(seed,chapters[3],dir).path==sentinel,
                'synthetic prior chapter would not be reused')
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
            assert(text==sentinel_bytes and not io.open(sentinel..'.part','rb'),'stale publication replaced the existing file')
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
    local shadow_checked,annotation_checked,reader_exact=false,false,false
    if kind=='large-id' then
        assert(id=='9007199254740993')
        local foreign={title='adjacent legacy record',annotation_documents={[reader.document.file]={clean=true,chapters={}}}}
        local records={[9007199254740992]=foreign}
        local get,get_book=settings.get,settings.get_book
        settings.get=function(self,key,default)
            if key=='books' then return records end
            return get(self,key,default)
        end
        settings.get_book=function(_,requested)
            return require('weread.lib.read_access').cached_key(records,requested)
        end
        local binding,context,active=host._annotationBinding,host._annotation_context,host._unified_annotations_active
        host._annotationBinding=function() return {book_id=id,automatic=true} end
        host._annotation_context=nil;host._unified_annotations_active=nil
        assert(not host:_usesUnifiedAnnotations(),'reader accepted adjacent legacy annotation')
        local annotation=assert(host:_prepareAnnotationContext(false))
        assert(annotation.book==nil and annotation.descriptor==nil,'reader associated adjacent legacy annotation')
        host._annotationBinding=binding;host._annotation_context=context;host._unified_annotations_active=active
        settings.get,settings.get_book=get,get_book;annotation_checked=true
        local apply=host.downloader._applyPrefetchResult
        host.downloader._applyPrefetchResult=function(self,job,result)
            self._applyPrefetchResult=apply
            assert(result.ok and result.value.book_id==id and result.value.chapter_uid=='3',
                'worker did not preserve exact large book identity')
            local shadow_books={[9007199254740992]=foreign}
            local shadow_settings={get=function(_,key,default) if key=='books' then return shadow_books end return default end,
                record_download=function(_,requested,synthetic,change)
                    local record,conflict=require('weread.lib.read_access').cached_book_for_update(shadow_books,requested)
                    if conflict then return false,'book_identity_conflict' end
                    record=record or {book_id=synthetic.book_id}
                    require('weread.lib.book_store').apply_download(record,change)
                    shadow_books[requested]=record
                    return true,record
                end}
            local shadow=require('weread.lib.downloader'):new{settings=shadow_settings,refresh_shelf=function() end}
            local shadow_job={book={book_id=id},chapters={{chapterUid='3'}},prefetch=true,
                prefetch_book_id=id,prefetch_chapter_uid='3'}
            local value={};for key,item in pairs(result.value) do if key~='auth' then value[key]=item end end
            shadow._active_job=shadow_job;shadow:_applyPrefetchResult(shadow_job,{ok=true,value=value})
            assert(not foreign.cached_chapters and shadow_books[id]~=foreign and shadow_books[id].book_id==id
                and shadow_books[id].cached_chapters['3']==value.path,'worker result aliased adjacent legacy book')
            shadow_checked=true
            return apply(self,job,result)
        end
    end
    local succeeds=kind=='stale' or kind=='promoted-success' or kind=='large-id'
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
    if kind=='promoted-success' or kind=='large-id' then
        pump(function() return Reader.instance and Reader.instance~=reader end)
        local selected_reader=Reader.instance
        if kind=='large-id' then
            local identity=require('weread.lib.book_file_identity').read_document(selected_reader.document,id)
            assert(identity.book_id==id,'opened EPUB did not preserve exact large book identity')
            reader_exact=true
        end
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
    if kind~='promoted-success' and kind~='promoted-recovery' and kind~='large-id' then host.showInfo=old_info end
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    local file=assert(io.open(evidence..'/prefetch-condition.json','wb'))
    file:write(Json.encode{result='PASS',scenario=kind,chapter_requests=1,renewals=0,foreground_renewals=kind=='promoted-recovery' and 1 or 0,
        stale_did_not_open=kind=='stale',rate_message=kind=='rate',promoted_confirmation=kind=='promoted-expired' or kind=='promoted-recovery',
        promoted_opened=kind=='promoted-success' or kind=='promoted-recovery' or kind=='large-id',foreground_recovery=kind=='promoted-recovery',
        shadow_foreign_preserved=shadow_checked,reader_annotation_not_bound=annotation_checked,reader_exact_book_id=reader_exact});file:close()
    return reader,host
end
