-- Synthetic EPUB recovery through the real chooser, records and stock reader.
return function(c)
    local UI=require('ui/uimanager');local Screen=require('device').screen
    local socket=require('socket');local fs=require('libs/libkoreader-lfs')
    local Content=require('weread.lib.content');local Identity=require('weread.lib.mp_cache_identity')
    local Versions=require('weread.lib.mp_cache_versions');local Recovery=require('weread.ui.mp_record_recovery')
    local Actions=require('weread.ui.mp_article_actions')
    local Data=require('weread.lib.mp_record_data');local Store=require('weread.lib.mp_records_db')
    local Crypto=require('weread.lib.crypto');local Epub=require('weread.lib.mp_epub_records')
    local entries,cases={},{}
    local function write(path,raw) local f=assert(io.open(path,'wb'));assert(f:write(raw));f:close() end
    local function pump(predicate)
        local deadline=socket.gettime()+25
        while not predicate() do assert(socket.gettime()<deadline,'EPUB recovery deadline');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    assert(os.rename(c.book.cache_dir..'/mp-articles',c.evidence..'/epub-unused-seeds'))
    local article={reviewId='epub-record-fixture',title='旧 EPUB：正文、图片与笔记'}
    c.book.mp_articles={article};c.settings:set('books',{[c.book.book_id]=c.book});c.settings:flush()
    local key=assert(Identity.key(c.book,article));local source=Content.mp_article_legacy_path(c.settings,c.book,article):gsub('%.html$','.epub')
    local BB=require('ffi/blitbuffer');local image=c.book.cache_dir..'/epub-original-image.png'
    local bitmap=BB.new(48,48,BB.TYPE_BB8);bitmap:fill(BB.COLOR_BLACK);bitmap:paintRect(24,0,24,48,BB.COLOR_WHITE)
    bitmap:writePNG(image);bitmap:free();local image_bytes=c.read(image)
    local output=assert(require('weread.lib.notes_export_file').create(c.book.cache_dir,'epub-seed','epub'))
    local writer=require('weread.lib.epub_export_writer').new(output.fd)
    writer:add('mimetype','application/epub+zip',20,true)
    local original={
        {'META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'},
        {'EPUB/package.opf','<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">synthetic-epub-records</dc:identifier><dc:title>旧 EPUB</dc:title><dc:language>zh-CN</dc:language></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="css" href="style.css" media-type="text/css"/><item id="png" href="images/original.png" media-type="image/png"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>'},
        {'EPUB/nav.xhtml','<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">第一章</a></li><li><a href="two.xhtml">第二章</a></li></ol></nav></body></html>'},
        {'EPUB/style.css','body{line-height:1.7} img{max-width:100%} p{margin:1em 0}'},
        {'EPUB/one.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title><link rel="stylesheet" href="style.css"/></head><body><h1>EPUBTEXT 第一章</h1><p><img src="images/original.png" width="48" height="48"/></p>'..string.rep('<p>这是一份合成的旧 EPUB。原始章节、图片和笔记位置保持完整。沿着山谷的小路继续阅读。</p>',160)..'</body></html>'},
        {'EPUB/two.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章</title><link rel="stylesheet" href="style.css"/></head><body><h1>第二章</h1>'..string.rep('<p>第二章有独立的段落和位置。恢复副本不能改变目录顺序或章节路径。</p>',160)..'</body></html>'},
        {'EPUB/images/original.png',image_bytes},
    }
    for _i,row in ipairs(original) do writer:add(row[1],row[2],#row[2]) end
    assert(writer:close() and output:sync());local size=assert(fs.attributes(output.path,'size'));assert(output:accept(size));assert(os.rename(output.path,source))
    local bytes=c.read(source);local source_hash=require('util').partialMD5(source)
    local function annotate(reader,note)
        local selection=assert(reader.document:getTextFromPositions({x=1,y=1},{x=Screen:getWidth()-2,y=Screen:getHeight()-2},true))
        reader.annotation:addItem{page=selection.pos0,pos0=selection.pos0,pos1=selection.pos1,text=selection.text,
            note=note,drawer='lighten',datetime='2026-11-09 22:00:00'}
    end
    c.choose('hash');local reader=c.open(source);reader.rolling:onGotoPage(3);reader.bookmark:onToggleBookmark();annotate(reader,'EPUB 原始附注');c.close(reader)
    local function start(path,location)
        c.choose('hash');local value=c.open(path);c.choose(location,value)
        local host=value.weread;local open=host.openFile;local opened
        host.openFile=function(_self,path_value) opened=path_value end
        return value,host,open,function() return opened end
    end
    local function finish(value,host,open) host.openFile=open;host:closeWeReadUI();c.close(value) end
    local function history(host)
        assert(Actions.history(host,c.book,article));local rows=assert(Versions.list(c.book.cache_dir,key))
        host._mp_versions_menu.item_table[#rows+1].callback()
    end
    local function choices(host)
        pump(function() return host._mp_records_menu or not host.mp_records_job end);assert(host._mp_records_menu,'EPUB did not reach chooser')
        local store=assert(Store.new(host.settings,host.library_db:accountKey()));return store,assert(store:list(key))
    end
    local function choose(host,rows,notes,kind)
        for index,row in ipairs(rows) do
            if row.valid and row.notes==notes and row.bookmarks==1 and (not kind or row.kind==kind) then
                host._mp_records_menu.item_table[index].callback();return assert(host._mp_records_confirmation),row
            end
        end
        error('chosen EPUB snapshot missing')
    end
    local function entry(path,location,store,row)
        local raw=row and assert(store:get(key,row.id));local data=raw and Data.record(raw) or require('docsettings'):open(path).data
        assert(require('util').partialMD5(path)~=source_hash and Epub.header(c.read(path):sub(1,1024),key),'EPUB copy retained shared source identity')
        return {path=path,location=location,word='EPUBTEXT',annotations=c.projection(data.annotations),xpointer=data.last_xpointer,
            body_sha256=Crypto.sha256_hex(c.read(path)),article_key=key,record_id=row and row.id,
            record_sha256=raw and Crypto.sha256_hex(raw),resource_artifact=true,exported=true,
            source_html=source,source_html_sha256=Crypto.sha256_hex(bytes),source_image=image,source_image_sha256=Crypto.sha256_hex(image_bytes)}
    end
    local host,open,opened
    reader,host,open,opened=start(source,'doc')
    assert(Actions.show(host,c.book,article) and host._mp_actions_menu.item_table[6].select_enabled)
    host:showMPArticleList(c.book,{article});local selected_row
    for _i,row in ipairs(host._mp_article_list_view.item_table) do if row.text==article.title then selected_row=row end end
    assert(selected_row);selected_row.callback()
    local store,rows=choices(host);assert(not opened() and not fs.symlinkattributes(Identity.path(c.book.cache_dir,key):match('^(.*)/[^/]+$')))
    UI:forceRePaint();Screen:shot(c.evidence..'/mp-epub-choices.png')
    local confirm,chosen=choose(host,rows,1);UI:forceRePaint();Screen:shot(c.evidence..'/mp-epub-confirm.png')
    local Reader=require('apps/reader/readerui');local create=Reader.new;local created=0;local old=reader
    Reader.new=function(class,options) created=created+1;return create(class,options) end
    host.openFile=open;confirm.ok_callback()
    pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.document
        and Reader.instance.document.file==Versions.resolve(c.book.cache_dir,key) end)
    Reader.new=create;assert(created==1);c.count_external_open(created)
    reader=Reader.instance;local restored=entry(reader.document.file,'doc',store,chosen)
    assert(c.same(c.projection(reader.annotation.annotations),restored.annotations));c.close(reader)
    restored.preview_png=c.evidence..'/mp-epub-reader.png';c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='article_entry_handoff',first_identity_tree=true,stock_reader_instances=created}
    reader,host,open,opened=start(restored.path,'dir');history(host);store,rows=choices(host)
    confirm,chosen=choose(host,rows,1);confirm.ok_callback();pump(function() return not host.mp_records_job end)
    restored=entry(assert(opened()),'dir',store,chosen);finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='history_to_dir',explicit_confirmation=true}
    reader,host,open,opened=start(source,'hash');reader.rolling:onGotoPage(math.floor(reader.document:getPageCount()*.7))
    assert(reader.document:getXPointer():find('DocFragment[2]',1,true),'live EPUB fixture did not reach the second spine chapter')
    annotate(reader,'EPUB 未关书附注');history(host);store,rows=choices(host)
    confirm,chosen=choose(host,rows,2,'live');confirm.ok_callback();pump(function() return not host.mp_records_job end)
    restored=entry(assert(opened()),'hash',store,chosen);finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='live_second_chapter_to_hash',unclosed_notes_preserved=true}
    reader,host,open,opened=start(source,'doc');history(host);rows=select(2,choices(host));confirm=choose(host,rows,1)
    local before=assert(Versions.resolve(c.book.cache_dir,key));write(source,bytes..'changed');confirm.ok_callback()
    pump(function() return not host.mp_records_job end);assert(not opened() and Versions.resolve(c.book.cache_dir,key)==before)
    write(source,bytes);finish(reader,host,open);cases[#cases+1]={kind='source_changed',current_kept=true}
    reader,host,open,opened=start(source,'doc');history(host);rows=select(2,choices(host))
    local copy=Epub.write;local ready=c.evidence..'/epub-copy-ready'
    Epub.write=function(...) write(ready,'ready');socket.sleep(10);return copy(...) end
    choose(host,rows,1).ok_callback();Epub.write=copy;pump(function() return fs.symlinkattributes(ready)~=nil end)
    local stage=assert(host.mp_records_job.stage);local worker=host.mp_records_worker;local pid=assert(worker.job.pid)
    assert(not worker.runner.done(pid));host:closeWeReadUI();pump(function() return worker.runner.done(pid) and not fs.symlinkattributes(stage.directory) end)
    assert(not opened() and Versions.resolve(c.book.cache_dir,key)==before);finish(reader,host,open)
    cases[#cases+1]={kind='cancel_live_copy',child_reaped=true,stage_cleaned=true}
    reader,host,open,opened=start(source,'doc');history(host);store,rows=choices(host);confirm,chosen=choose(host,rows,1)
    local rename,io_open=os.rename,io.open;local unknown=false;local selector=Identity.path(c.book.cache_dir,key):match('^(.*)/[^/]+$')..'/current'
    rawset(os,'rename',function(from,to) local result=rename(from,to);if result and to==selector then unknown=true end;return result end)
    rawset(io,'open',function(path,...) if unknown and path==selector then return nil end;return io_open(path,...) end)
    confirm.ok_callback();stage=assert(host.mp_records_job.stage);pump(function() return not host.mp_records_job and not stage.lease end)
    rawset(os,'rename',rename);rawset(io,'open',io_open)
    local retained=assert(Versions.resolve(c.book.cache_dir,key));assert(retained~=before and not opened())
    restored=entry(retained,'doc',store,chosen);finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='selector_readback_unknown',complete_package_retained=true,no_false_success=true}
    reader,host,open,opened=start(source,'dir');history(host);choices(host)
    local menu=host._mp_records_menu;menu.item_table[#menu.item_table-1].callback();host._mp_records_confirmation.ok_callback()
    pump(function() return not host.mp_records_job end);local fresh=assert(opened());finish(reader,host,open)
    c.choose('dir');reader=c.open(fresh);assert(#reader.annotation.annotations==0);c.close(reader)
    restored=entry(fresh,'dir');c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='fresh_copy',no_records_applied=true}
    reader,host,open,opened=start(fresh,'dir');assert(Recovery.open(host,c.book,article,fresh) and opened()==fresh and not host.mp_records_job)
    finish(reader,host,open);cases[#cases+1]={kind='managed_direct_read',no_extra_recovery_prompt=true}
    reader,host,open,opened=start(entries[1].path,'dir')
    assert(Recovery.show(host,c.book,article,entries[1].path));store,rows=choices(host)
    confirm,chosen=choose(host,rows,1);confirm.ok_callback();pump(function() return not host.mp_records_job end)
    restored=entry(assert(opened()),'dir',store,chosen)
    assert(#c.read(restored.path)==#c.read(entries[1].path) and require('util').partialMD5(restored.path)~=require('util').partialMD5(entries[1].path))
    finish(reader,host,open);c.verify(restored);entries[#entries+1]=restored
    cases[#cases+1]={kind='managed_epub_recovery',identity_replaced_without_growing_archive=true}
    local Stage=require('weread.lib.mp_download_stage');stage=assert(Stage.create(c.book.cache_dir,key,{preserve=true}))
    local revision=assert(stage.version_name:match('article%-([a-f0-9]+)%.html$'))
    local html=Content.render_mp_article_html(article,'<p>'..string.rep('新的合成正文不复制旧 EPUB 坐标。',1500)..'</p>',key,revision)
    assert(stage.output:write(html) and stage.output:sync())
    local new_html=assert(stage:commit({ok=true,bytes=#html,images=0,image_bytes=0}))
    assert(Versions.resolve(c.book.cache_dir,key)==new_html and not require('docsettings'):open(new_html):readSetting('annotations'))
    reader=c.open(new_html);c.close(reader);cases[#cases+1]={kind='html_refresh_after_epub',old_packages_retained=true,no_old_coordinates=true}
    local Cleanup=require('weread.lib.mp_cache_cleanup');local lock=assert(Cleanup.acquire(c.book.cache_dir,key))
    local plan=Cleanup.scan(c.book.cache_dir,key,nil,lock.info);assert(#plan.versions==7)
    assert(not pcall(Cleanup.targets,plan,new_html:match('[^/]+$')))
    local job=Cleanup.begin(plan,nil,lock);local good,state
    repeat good,state=Cleanup.step(job);assert(good) until state=='done';lock:release()
    assert(not require('weread.lib.mp_download_recovery').scan(c.book.cache_dir,key,nil).active)
    for _i,row in ipairs(entries) do c.verify(row) end
    cases[#cases+1]={kind='cleanup_embedded_resources',independent_of_removed_asset_generations=true}
    local cases_raw=require('json').decode(c.read(c.evidence..'/epub-cases/cases.json'))
    local done,archive_results=false
    local ffi=require('ffi');local parent=tonumber(ffi.C.getpid())
    local codec={json_encode=function(_self,value) return require('json').encode(value) end,
        json_decode=function(_self,value) return require('json').decode(value) end}
    local archive_worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=codec,max_bytes=512*1024}
    assert(require('util').makePath(c.evidence..'/epub-variant-copies'))
    assert(archive_worker:start(function()
        assert(tonumber(ffi.C.getpid())~=parent,'archive validation ran on UI thread')
        local result={allowed=0,rejected=0,copies={}}
        for _i,row in ipairs(cases_raw) do
            local path=c.evidence..'/epub-cases/'..row.name..'.epub';local info=fs.symlinkattributes(path)
            local accepted,inspection=pcall(Epub.inspect,path,info,key)
            if accepted~=row.allowed then return {mismatch=row.name,actual=accepted,expected=row.allowed} end
            if accepted then
                local target=assert(require('weread.lib.notes_export_file').create(c.evidence..'/epub-variant-copies',row.name,'epub'))
                local receipt=Epub.write({path=path,info=info,key=key},target,'0123456789abcdef',inspection.source_sha256)
                assert(target:accept(receipt.bytes));result.allowed=result.allowed+1
                result.copies[#result.copies+1]={source=path,path=target.path}
            else result.rejected=result.rejected+1 end
        end
        return result
    end,function(result) archive_results=result;done=true end))
    pump(function() return done end)
    assert(archive_results and not archive_results.error and not archive_results.mismatch,
        'archive fixture mismatch: '..tostring(archive_results and archive_results.mismatch))
    assert(archive_results.allowed==6 and archive_results.rejected==16)
    cases[#cases+1]={kind='archive_boundaries',accepted=archive_results.allowed,rejected=archive_results.rejected,actual_child=true}
    assert(c.read(source)==bytes and c.read(image)==image_bytes)
    write(c.evidence..'/mp-epub-package.json',require('json').encode({source=source,result='PASS',synthetic_only=true,
        run_root=c.home:match('^(.*)/profile$'),copies=entries,variants=archive_results.copies}))
    return {entries=entries,cases=cases,expected_reader_opens=27}
end
