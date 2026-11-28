-- Synthetic legacy title HTML, native records, image relocation and handoff.
return function(c)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local socket=require('socket')
    local Content=require('weread.lib.content')
    local Identity=require('weread.lib.mp_cache_identity')
    local Versions=require('weread.lib.mp_cache_versions')
    local Actions=require('weread.ui.mp_article_actions')
    local Recovery=require('weread.ui.mp_record_recovery')
    local Model=require('weread.lib.mp_record_recovery')
    local Assets=require('weread.lib.mp_record_assets')
    local Store=require('weread.lib.mp_records_db')
    local Data=require('weread.lib.mp_record_data')
    local Crypto=require('weread.lib.crypto')
    local lfs=require('libs/libkoreader-lfs')
    local entries,cases={},{}
    local function write(path,raw)
        local file=assert(io.open(path,'wb'));assert(file:write(raw));file:close()
    end
    local function pump(predicate)
        local deadline=socket.gettime()+25
        while not predicate() do
            assert(socket.gettime()<deadline,'title recovery deadline')
            UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
        end
    end
    -- The common collision seeds are unrelated to this article. Move only
    -- those synthetic files aside, so the first migration creates its tree.
    assert(os.rename(c.book.cache_dir..'/mp-articles',c.evidence..'/title-unused-seeds'))
    local article={reviewId='title-record-fixture',title='旧标题文章：阅读记录'}
    c.book.mp_articles={article}
    c.settings:set('books',{[c.book.book_id]=c.book});c.settings:flush()
    local key=assert(Identity.key(c.book,article))
    local source=Content.mp_article_legacy_path(c.settings,c.book,article)
    local directory=c.book.cache_dir..'/'..Content.mp_article_asset_name(c.book,article)
    assert(require('util').makePath(directory))
    local source_image=directory..'/img-0001.png'
    local BB=require('ffi/blitbuffer')
    local bitmap=BB.new(48,48,BB.TYPE_BB8);bitmap:fill(BB.COLOR_BLACK)
    bitmap:paintRect(24,0,24,48,BB.COLOR_WHITE);bitmap:writePNG(source_image);bitmap:free()
    local tiny=c.book.cache_dir..'/title-embedded-fixture.png'
    bitmap=BB.new(1,1,BB.TYPE_BB8);bitmap:fill(BB.COLOR_WHITE);bitmap:writePNG(tiny);bitmap:free()
    local embedded=require('mime').b64(c.read(tiny))
    local asset=Content.mp_article_asset_name(c.book,article)
    local body='<p><img src="'..asset..'/img-0001.png" width="48" height="48"/>'
        .."<img src='./"..asset.."/img-0001.png' width='48' height='48'/>"
        ..'<img src="'..asset..'/img-0002.png"/><img src="data:image/png;base64,'..embedded..'"/>'
        ..'<img src="https://example.invalid/unavailable.png"/></p><p>'
        ..string.rep('A',6000)..'TITLETEXT'..string.rep('B',24000)..'</p>'
    local html=Content.render_mp_article_html(article,body,key):gsub(Identity.marker(key):gsub('([^%w])','%%%1'),'')
    write(source,html)
    local original_image=c.read(source_image)
    local body_sha=Crypto.sha256_hex(Assets.rewrite(assert(html:match('<body>.*</body>')),function() return 'IMAGE' end))
    local function decorate(path,location,store,row)
        local raw=assert(store:get(key,row.id));local data=Data.record(raw)
        return {path=path,location=location,word='TITLETEXT',annotations=c.projection(data.annotations),
            xpointer=data.last_xpointer,body_sha256=Crypto.sha256_hex(c.read(path)),article_key=key,
            record_id=row.id,record_sha256=Crypto.sha256_hex(raw),resource_artifact=true,
            source_html=source,source_html_sha256=Crypto.sha256_hex(html),source_image=source_image,
            source_image_sha256=Crypto.sha256_hex(original_image),canonical_body_sha256=body_sha}
    end
    local function annotate(reader,note)
        local size=Screen:getSize()
        local selected=assert(reader.document:getTextFromPositions({x=1,y=1},{x=size.w-2,y=size.h-2},true))
        reader.annotation:addItem{page=selected.pos0,pos0=selected.pos0,pos1=selected.pos1,text=selected.text,
            note=note,drawer='lighten',datetime='2026-11-09 20:00:00'}
    end
    c.choose('hash');local reader=c.open(source)
    reader.rolling:onGotoPage(2);reader.bookmark:onToggleBookmark();annotate(reader,'旧标题附注')
    c.close(reader)
    local function start(path,location)
        c.choose('hash');local value=c.open(path);c.choose(location,value)
        local host=assert(value.weread);local open=host.openFile;local opened
        host.openFile=function(_self,selected) opened=selected end
        return value,host,open,function() return opened end
    end
    local function wait_choice(host)
        pump(function() return host._mp_records_menu~=nil or host.mp_records_job==nil end)
        assert(host._mp_records_menu,'legacy title did not reach native record chooser')
        local store=assert(Store.new(host.settings,assert(host.library_db:accountKey())))
        return store,assert(store:list(key))
    end
    local function choose(host,rows,kind,notes)
        for index,row in ipairs(rows) do
            if row.valid and row.notes==notes and row.bookmarks==1 and (not kind or row.kind==kind) then
                host._mp_records_menu.item_table[index].callback()
                return assert(host._mp_records_confirmation),row
            end
        end
        error('explicit title record missing')
    end
    local function history(host)
        assert(Actions.history(host,c.book,article))
        local rows=assert(Versions.list(c.book.cache_dir,key))
        host._mp_versions_menu.item_table[#rows+1].callback()
    end
    local function finish(value,host,open)
        host.openFile=open;host:closeWeReadUI();c.close(value)
    end
    -- Actual article-list opening protects a legacy file before the first tree
    -- exists; confirmation then uses the stock switchDocument/showReader path.
    local host,open,opened
    reader,host,open,opened=start(source,'doc')
    assert(not lfs.symlinkattributes(c.book.cache_dir..'/mp-articles'))
    assert(Actions.show(host,c.book,article) and host._mp_actions_menu.item_table[6].select_enabled)
    host:showMPArticleList(c.book,{article})
    local row
    for _i,item in ipairs(host._mp_article_list_view.item_table) do if item.text==article.title then row=item end end
    assert(row);row.callback()
    local store,rows=wait_choice(host)
    assert(not opened() and not lfs.symlinkattributes(Identity.path(c.book.cache_dir,key):match('^(.*)/[^/]+$')))
    UIManager:forceRePaint();Screen:shot(c.evidence..'/mp-title-choices.png')
    local confirm,selected=choose(host,rows,nil,1)
    UIManager:forceRePaint();Screen:shot(c.evidence..'/mp-title-confirm.png')
    local Reader=require('apps/reader/readerui');local create=Reader.new;local created=0
    Reader.new=function(class,options) created=created+1;return create(class,options) end
    local old_reader=reader;host.openFile=open;confirm.ok_callback()
    pump(function() return Reader.instance and Reader.instance~=old_reader and Reader.instance.document
        and Reader.instance.document.file==Versions.resolve(c.book.cache_dir,key) end)
    Reader.new=create;assert(created==1);c.count_external_open(created)
    reader=assert(Reader.instance)
    local restored=decorate(reader.document.file,'doc',store,selected)
    assert(c.same(c.projection(reader.annotation.annotations),restored.annotations)
        and reader.document:isXPointerInCurrentPage(restored.xpointer))
    c.close(reader);restored.preview_png=c.evidence..'/mp-title-reader.png';c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='article_entry_handoff',first_identity_tree=true,explicit_confirmation=true,new_reader_instances=created}
    -- History retains access to the original title file after a managed copy
    -- becomes current; its records can target another metadata location.
    reader,host,open,opened=start(entries[1].path,'dir');history(host)
    store,rows=wait_choice(host);confirm,selected=choose(host,rows,nil,1);confirm.ok_callback()
    pump(function() return host.mp_records_job==nil end);assert(opened())
    restored=decorate(opened(),'dir',store,selected);finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='legacy_history_to_dir',explicit_confirmation=true}
    reader,host,open,opened=start(source,'hash')
    reader.rolling:onGotoPage(4)
    for _i,item in ipairs(reader.annotation.annotations) do if item.drawer then item.note='未关书附注' end end
    annotate(reader,'未关书附注')
    history(host);store,rows=wait_choice(host);confirm,selected=choose(host,rows,'live',2)
    assert(confirm.text:find('未关书附注',1,true));confirm.ok_callback()
    pump(function() return host.mp_records_job==nil end);assert(opened())
    restored=decorate(opened(),'hash',store,selected);finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='legacy_live_to_hash',unclosed_notes_preserved=true}
    reader,host,open,opened=start(source,'doc');history(host);rows=select(2,wait_choice(host))
    local before=assert(Versions.resolve(c.book.cache_dir,key))
    write(source_image,original_image..'changed-after-preview')
    choose(host,rows,nil,1).ok_callback();pump(function() return host.mp_records_job==nil end)
    assert(not opened() and Versions.resolve(c.book.cache_dir,key)==before)
    write(source_image,original_image);finish(reader,host,open)
    cases[#cases+1]={kind='source_bitmap_changed',current_kept=true}
    reader,host,open,opened=start(source,'doc');history(host);rows=select(2,wait_choice(host))
    confirm=choose(host,rows,nil,1)
    local saved=host.settings:get('books',{});saved[c.book.book_id].mp_articles={article,{reviewId='conflict',title=article.title}}
    host.settings:set('books',saved);host.settings:flush();confirm.ok_callback()
    assert(not host.mp_records_job and not opened())
    saved[c.book.book_id].mp_articles={article};host.settings:set('books',saved);host.settings:flush()
    finish(reader,host,open);cases[#cases+1]={kind='catalog_changed',no_file_opened=true}
    reader,host,open,opened=start(source,'doc');history(host);rows=select(2,wait_choice(host))
    local writer=Model.write;local ready=c.evidence..'/title-copy-ready'
    Model.write=function(...) write(ready,'ready');socket.sleep(10);return writer(...) end
    choose(host,rows,nil,1).ok_callback();Model.write=writer
    pump(function() return lfs.symlinkattributes(ready)~=nil end)
    local stage=assert(host.mp_records_job.stage);local worker=host.mp_records_worker;local pid=assert(worker.job.pid)
    assert(not worker.runner.done(pid));host:closeWeReadUI()
    pump(function() return worker.runner.done(pid) and not lfs.symlinkattributes(stage.directory) end)
    assert(not opened() and Versions.resolve(c.book.cache_dir,key)==before)
    finish(reader,host,open);cases[#cases+1]={kind='cancel_live_copy',child_reaped=true,stage_cleaned=true}
    -- Preserve a body and its copied bitmap even when selector rename succeeded
    -- but the immediate readback is unavailable. Do not claim/open success.
    reader,host,open,opened=start(source,'doc');history(host);store,rows=wait_choice(host)
    confirm,selected=choose(host,rows,nil,1)
    local rename,io_open=os.rename,io.open;local unknown=false
    local selector=Identity.path(c.book.cache_dir,key):match('^(.*)/[^/]+$')..'/current'
    rawset(os,'rename',function(from,to)
        local result=rename(from,to);if result and to==selector then unknown=true end;return result
    end)
    rawset(io,'open',function(path,...) if unknown and path==selector then return nil end;return io_open(path,...) end)
    confirm.ok_callback();stage=assert(host.mp_records_job.stage)
    pump(function() return host.mp_records_job==nil and stage.lease==nil end)
    rawset(os,'rename',rename);rawset(io,'open',io_open)
    local retained=assert(Versions.resolve(c.book.cache_dir,key))
    assert(retained~=before and not opened() and lfs.symlinkattributes(stage.directory..'/images/img-0001.png'))
    restored=decorate(retained,'doc',store,selected);finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='selector_readback_unknown',complete_body_and_bitmap_retained=true,no_false_success=true}
    reader,host,open,opened=start(source,'doc')
    local plain={reviewId='title-no-records',title='无阅读记录的大型旧标题'}
    local plain_path=Content.mp_article_legacy_path(host.settings,c.book,plain)
    write(plain_path,'<html><head><style>p{background:url(unknown.png)}</style></head><body>'..string.rep('Z',4*1024*1024)..'</body></html>')
    saved=host.settings:get('books',{});saved[c.book.book_id].mp_articles={article,plain}
    host.settings:set('books',saved);host.settings:flush()
    assert(Recovery.open(host,c.book,plain,plain_path));pump(function() return host.mp_records_job==nil end)
    assert(opened()==plain_path and not lfs.symlinkattributes(Identity.path(c.book.cache_dir,Identity.key(c.book,plain)):match('^(.*)/[^/]+$')))
    cases[#cases+1]={kind='large_no_records_direct_read',no_copy_or_resource_parse_required=true}
    host:showMPArticleExport(c.book,article);assert(host._mp_export_picker).ok_callback()
    pump(function() return host.mp_export_job==nil end);assert(host._mp_export_result,'relocated article export failed')
    local export_dir=assert(require('weread.lib.mp_export').directory(host.settings));local exports={}
    for name in lfs.dir(export_dir) do if name:match('%.epub$') then exports[#exports+1]=export_dir..'/'..name end end
    assert(#exports==1)
    write(c.evidence..'/mp-title-export.json',require('json').encode({path=exports[1],source_image=source_image,source_tiny=tiny,
        source_article=source,run_root=c.home:match('^(.*)/profile$'),result='PASS',synthetic_only=true}))
    local create_export=Reader.new;local export_created=0;local source_reader=reader
    Reader.new=function(class,options) export_created=export_created+1;return create_export(class,options) end
    host.openFile=open;host._mp_export_result.ok_callback()
    pump(function() return Reader.instance and Reader.instance~=source_reader and Reader.instance.document
        and Reader.instance.document.file==exports[1] end)
    Reader.new=create_export;assert(export_created==1);c.count_external_open(export_created)
    local exported=assert(Reader.instance)
    assert(exported.document:getPageCount()>=6 and #exported.annotation.annotations==0)
    local artifact={};for name,value in pairs(entries[4]) do artifact[name]=value end
    artifact.exported,artifact.path,artifact.xpointer=true,exports[1],exported.document:getXPointer();artifact.preview_png=nil
    dofile(assert(debug.getinfo(1,'S').source:match('^@(.*/)'))..'mp_title_record_images.lua')(artifact,exported)
    c.close(exported)
    cases[#cases+1]={kind='native_epub_export',recovered_bitmap_and_embedded_image=true,stock_reader_opened=true}
    -- Some older caches have an implicit head. Inserting only a metadata head
    -- must preserve the real reader's body pointers, text and image positions.
    local headless={reviewId='title-headless-fixture',title='没有 head 的旧标题'}
    local headless_key=assert(Identity.key(c.book,headless))
    local headless_path=Content.mp_article_legacy_path(c.settings,c.book,headless)
    local headless_asset=Content.mp_article_asset_name(c.book,headless)
    local headless_dir=c.book.cache_dir..'/'..headless_asset
    assert(require('util').makePath(headless_dir));write(headless_dir..'/img-0001.png',original_image)
    local headless_html='<html><body><h1>'..headless.title..'</h1>'
        ..body:gsub(asset:gsub('([^%w])','%%%1'),headless_asset)..'</body></html>'
    write(headless_path,headless_html)
    saved=c.settings:get('books',{});saved[c.book.book_id].mp_articles={article,plain,headless}
    c.settings:set('books',saved);c.settings:flush()
    c.choose('hash');reader=c.open(headless_path)
    reader.rolling:onGotoPage(2);reader.bookmark:onToggleBookmark();annotate(reader,'没有 head 的附注');c.close(reader)
    reader,host,open,opened=start(headless_path,'doc')
    assert(Recovery.open(host,c.book,headless,headless_path))
    pump(function() return host._mp_records_menu~=nil or host.mp_records_job==nil end)
    assert(host._mp_records_menu)
    local headless_store=assert(Store.new(host.settings,host.library_db:accountKey()))
    local headless_rows=assert(headless_store:list(headless_key))
    confirm,selected=choose(host,headless_rows,nil,1);confirm.ok_callback()
    pump(function() return host.mp_records_job==nil end);assert(opened())
    local raw=assert(headless_store:get(headless_key,selected.id));local data=Data.record(raw)
    restored={path=opened(),location='doc',word='TITLETEXT',annotations=c.projection(data.annotations),xpointer=data.last_xpointer,
        body_sha256=Crypto.sha256_hex(c.read(opened())),article_key=headless_key,record_id=selected.id,record_sha256=Crypto.sha256_hex(raw),
        resource_artifact=true,source_html=headless_path,source_html_sha256=Crypto.sha256_hex(headless_html),
        source_image=headless_dir..'/img-0001.png',source_image_sha256=Crypto.sha256_hex(original_image),
        canonical_body_sha256=Crypto.sha256_hex(Assets.rewrite(assert(headless_html:match('<body>.*</body>')),function() return 'IMAGE' end))}
    finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='implicit_head_html',native_positions_and_bitmap_preserved=true}
    for _i,entry in ipairs(entries) do c.verify(entry) end
    assert(c.read(source)==html and c.read(source_image)==original_image)
    return {entries=entries,cases=cases,expected_reader_opens=25}
end
