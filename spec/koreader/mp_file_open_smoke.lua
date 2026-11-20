-- Actual FileManager instances, file rows, providers, record choices and ReaderUI.
return function(c)
    local UI=require('ui/uimanager');local FM=require('apps/filemanager/filemanager')
    local Reader=require('apps/reader/readerui');local Doc=require('docsettings')
    local Content=require('weread.lib.content');local Versions=require('weread.lib.mp_cache_versions')
    local Store=require('weread.lib.mp_records_db');local Data=require('weread.lib.mp_record_data')
    local Crypto=require('weread.lib.crypto');local socket=require('socket');local Screen=require('device').screen
    local Model=require('weread.lib.mp_record_recovery');local fs=require('libs/libkoreader-lfs')
    local entries,cases={},{}
    local legacy=Content.mp_article_legacy_path(c.settings,c.book,c.article)
    local epub=legacy:gsub('%.html$','.epub')
    local function write(path,raw) local f=assert(io.open(path,'wb'));assert(f:write(raw));f:close() end
    write(legacy,c.read(c.sources[1].path));write(epub,c.read(c.evidence..'/fm-seed.epub'))
    local original_html,original_epub=c.read(legacy),c.read(epub)
    local function pump(predicate)
        local deadline=socket.gettime()+25
        while not predicate() do assert(socket.gettime()<deadline,'file-manager deadline');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    c.choose('hash');local reader=c.open(epub);reader.rolling:onGotoPage(3);reader.bookmark:onToggleBookmark()
    local selection=assert(reader.document:getTextFromPositions({x=1,y=1},{x=Screen:getWidth()-2,y=Screen:getHeight()-2},true))
    reader.annotation:addItem{page=selection.pos0,pos0=selection.pos0,pos1=selection.pos1,text=selection.text,
        note='FM EPUB source',drawer='lighten',datetime='2026-11-09 23:00:00'}
    c.close(reader)
    local function browser(location)
        c.choose(location);FM:showFiles(c.book.cache_dir);local fm=assert(FM.instance)
        assert(fm.weread and fm.weread.ui==fm and not fm.document)
        Doc.setIsHashLocationEnabled(true);return fm,fm.weread
    end
    local function close_browser(fm,host)
        host:closeWeReadUI()
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=fm do UI:close(UI:getTopmostVisibleWidget()) end
        if FM.instance==fm then fm:onClose() end
    end
    local function choose_record(host,note)
        pump(function() return host._mp_records_menu or not host.mp_records_job end);assert(host._mp_records_menu,'FileManager bypassed chooser')
        if not fs.attributes(c.evidence..'/mp-manager-choices.png') then UI:forceRePaint();Screen:shot(c.evidence..'/mp-manager-choices.png') end
        local store=assert(Store.new(host.settings,host.library_db:accountKey()))
        for index,row in ipairs(assert(store:list(c.key))) do
            if row.valid then
                local raw=assert(store:get(c.key,row.id));local data=Data.record(raw)
                for _,annotation in ipairs(data.annotations or {}) do
                    if annotation.note==note then host._mp_records_menu.item_table[index].callback();return assert(host._mp_records_confirmation),row,store end
                end
            end
        end
        error('file-manager chosen record missing')
    end
    local function entry(path,location,row,store,is_epub)
        local raw=assert(store:get(c.key,row.id));local data=Data.record(raw)
        local value={path=path,location=location,word=is_epub and 'FM_EPUB_TEXT' or 'OLDTEXT',annotations=c.projection(data.annotations),
            xpointer=data.last_xpointer,body_sha256=Crypto.sha256_hex(c.read(path)),article_key=c.key,
            record_id=row.id,record_sha256=Crypto.sha256_hex(raw)}
        if is_epub then
            value.resource_artifact=true;value.exported=true;value.source_html=epub;value.source_html_sha256=Crypto.sha256_hex(original_epub)
            value.source_image=c.evidence..'/fm-seed.png';value.source_image_sha256=Crypto.sha256_hex(c.read(value.source_image))
            value.preview_png=c.evidence..'/mp-manager-reader.png'
        end
        return value
    end
    for index,scene in ipairs({{path=c.sources[1].path,location='doc',note='合成旧笔记 backup'},
        {path=legacy,location='dir',note='合成旧笔记 backup'},
        {path=epub,location='hash',note='FM EPUB source',epub=true}}) do
        local fm,host=browser(scene.location)
        local get_setting=host.settings.get
        host.settings.get=function(self,key,...)
            assert(key~='books','file-manager opening hydrated unrelated book collections')
            return get_setting(self,key,...)
        end
        local create=Reader.new;local created=0;local before_provider=false;local open=Doc.open
        local registry=require('document/documentregistry');local get_provider=registry.getProvider
        local expected=Model.freeze(Model.capture(host.settings,c.book,c.article,scene.path))
        local function preserved()
            local store=assert(Store.new(host.settings,host.library_db:accountKey()));local raw={}
            for _,row in ipairs(assert(store:list(c.key))) do raw[assert(store:get(c.key,row.id))]=true end
            for _,row in ipairs(expected) do assert(raw[row.raw],'native provider opened a candidate before its exact bytes were saved') end
        end
        local doc_pre,after=0,0
        Reader.new=function(class,options) created=created+1;return create(class,options) end
        registry.getProvider=function(self,path,...)
            if path==scene.path then preserved();before_provider=true end
            return get_provider(self,path,...)
        end
        Doc.open=function(class,path,...)
            if path==scene.path then
                preserved()
            end
            return open(class,path,...)
        end
        if index==2 then fm.file_chooser:onFileSelect({path=scene.path})
        else
            local provider=scene.epub and require('document/documentregistry'):getProviders(scene.path)[1].provider or nil
            fm:openFile(scene.path,provider,function() doc_pre=doc_pre+1 end,nil,function() after=after+1 end)
        end
        local dialog,row,store=choose_record(host,scene.note)
        preserved()
        assert(created==0 and FM.instance==fm and not Reader.instance,'reader created before explicit record confirmation')
        if not scene.epub then assert(before_provider,'native default provider route was not exercised') end
        if index==1 then UI:forceRePaint();Screen:shot(c.evidence..'/mp-manager-confirm.png') end
        dialog.ok_callback()
        pump(function() return Reader.instance and Reader.instance.document.file==Versions.resolve(c.book.cache_dir,c.key) end)
        Reader.new=create;Doc.open=open;registry.getProvider=get_provider;host.settings.get=get_setting;c.count_external_open(created)
        assert(created==1 and not FM.instance,'FileManager did not perform one native reader handoff')
        if index~=2 then assert(doc_pre==1 and after==1,'native provider/caller callback contract changed') end
        local restored=entry(Reader.instance.document.file,scene.location,row,store,scene.epub)
        assert(c.same(c.projection(Reader.instance.annotation.annotations),restored.annotations))
        c.close(Reader.instance);c.verify(restored);entries[#entries+1]=restored
        cases[#cases+1]={kind=scene.epub and 'forced_epub_provider' or index==2 and 'native_file_row_legacy_html' or 'native_filemanager_managed_html',
            stock_reader_instances=created,provider_lookup_observed=before_provider,all_raw_candidates_saved=true,explicit_confirmation=true,
            unrelated_book_collections_loaded=0}
    end
    local fm,host=browser('doc');fm:openFile(legacy)
    local dialog=choose_record(host,'合成旧笔记 backup');dialog.cancel_callback()
    assert(FM.instance==fm and not Reader.instance);close_browser(fm,host)
    cases[#cases+1]={kind='cancel_confirmation',filemanager_kept=true}
    fm,host=browser('doc');fm:openFile(legacy);dialog=choose_record(host,'合成旧笔记 backup')
    local prior=Versions.resolve(c.book.cache_dir,c.key);write(legacy,original_html..'changed')
    dialog.ok_callback();pump(function() return not host.mp_records_job end)
    assert(not Reader.instance and FM.instance==fm and Versions.resolve(c.book.cache_dir,c.key)==prior)
    write(legacy,original_html);close_browser(fm,host);cases[#cases+1]={kind='source_changed',current_kept=true}
    fm,host=browser('doc');local saved=host.settings:get('books',{})
    saved[c.book.book_id].mp_articles={c.article,{reviewId='ambiguous',title=c.article.title}}
    host.settings:set('books',saved);host.settings:flush();fm:openFile(legacy)
    assert(not host.mp_records_job and not Reader.instance and FM.instance==fm,'ambiguous legacy file was opened')
    saved[c.book.book_id].mp_articles={c.article};host.settings:set('books',saved);host.settings:flush();close_browser(fm,host)
    cases[#cases+1]={kind='ambiguous_title',no_reader_created=true}
    fm,host=browser('doc');fm:openFile(legacy);dialog=choose_record(host,'合成旧笔记 backup')
    local replacement,new_host=browser('doc');dialog.ok_callback()
    assert(not Reader.instance and FM.instance==replacement and not new_host.mp_records_job)
    close_browser(replacement,new_host);cases[#cases+1]={kind='replaced_filemanager',stale_confirmation_ignored=true}
    fm,host=browser('doc');local prepare=Model.prepare;local inspection_ready=c.evidence..'/manager-inspection-ready'
    Model.prepare=function(...) write(inspection_ready,'ready');socket.sleep(10);return prepare(...) end
    fm:openFile(legacy);Model.prepare=prepare;pump(function() return fs.symlinkattributes(inspection_ready) end)
    local inspection_worker=host.mp_records_worker;local inspection_pid=assert(inspection_worker.job.pid)
    assert(not inspection_worker.runner.done(inspection_pid));host:onSuspend()
    pump(function() return inspection_worker.runner.done(inspection_pid) end)
    assert(not host.mp_records_job and not Reader.instance and Versions.resolve(c.book.cache_dir,c.key)==prior)
    close_browser(fm,host);cases[#cases+1]={kind='suspend_inspection',child_reaped=true,no_reader_created=true}
    fm,host=browser('doc');fm:openFile(legacy);dialog=choose_record(host,'合成旧笔记 backup')
    local writer=Model.write;local ready=c.evidence..'/manager-copy-ready'
    Model.write=function(...) write(ready,'ready');socket.sleep(10);return writer(...) end
    dialog.ok_callback();Model.write=writer;pump(function() return fs.symlinkattributes(ready) end)
    local stage=assert(host.mp_records_job.stage);local worker=host.mp_records_worker;local pid=assert(worker.job.pid)
    assert(not worker.runner.done(pid));local cancelled_at=socket.gettime();fm:onClose()
    pump(function() return worker.runner.done(pid) and not fs.symlinkattributes(stage.directory) end)
    assert(socket.gettime()-cancelled_at<3,'closed FileManager left its recovery child running')
    assert(not Reader.instance and Versions.resolve(c.book.cache_dir,c.key)==prior)
    cases[#cases+1]={kind='close_filemanager_during_copy',child_reaped=true,stage_cleaned=true}
    fm,host=browser('doc');local edited,aux_called,doc_called=0,0,0
    fm:openFile(legacy,{provider='synthetic-editor',order=1,callback=function(path) assert(path==legacy);edited=edited+1 end},
        function() doc_called=doc_called+1 end,function() aux_called=aux_called+1 end)
    assert(edited==1 and aux_called==1 and doc_called==0 and not host.mp_records_job and not Reader.instance)
    close_browser(fm,host);cases[#cases+1]={kind='auxiliary_editor',native_route_kept=true}
    local function open_direct(path,expected_book)
        local create=Reader.new;local created=0
        Reader.new=function(class,options) created=created+1;return create(class,options) end
        fm:openFile(path);pump(function() return Reader.instance~=nil end)
        Reader.new=create;c.count_external_open(created)
        assert(created==1 and not FM.instance and Reader.instance.document.file==path
            and Reader.instance.weread:detectWeReadBook()==expected_book)
        assert(#Reader.instance.annotation.annotations==0);c.close(Reader.instance)
    end
    fm,host=browser('doc');local plain={reviewId='manager-no-records',title='没有阅读记录的文章'}
    local plain_path=Content.mp_article_legacy_path(host.settings,c.book,plain)
    write(plain_path,Content.render_mp_article_html(plain,'<p>'..string.rep('没有记录的合成文章仍然可以直接阅读。',1500)..'</p>',require('weread.lib.mp_cache_identity').key(c.book,plain)))
    saved=host.settings:get('books',{});saved[c.book.book_id].mp_articles={c.article,plain}
    host.settings:set('books',saved);host.settings:flush();open_direct(plain_path,c.book.book_id)
    cases[#cases+1]={kind='no_records_direct_read',original_file_opened=true,no_copy_created=true}
    fm,host=browser('doc');local outside=c.home:match('^(.*)/profile$')..'/books/standalone.html'
    write(outside,'<html><body><h1>普通本地文件</h1><p>'..string.rep('普通本地文件不进入微信读书恢复流程。',1500)..'</p></body></html>')
    open_direct(outside,nil);cases[#cases+1]={kind='unrelated_local_file',native_route_kept=true}
    for _,value in ipairs(entries) do c.verify(value) end
    assert(c.read(legacy)==original_html and c.read(epub)==original_epub)
    return {entries=entries,cases=cases,expected_reader_opens=14}
end
