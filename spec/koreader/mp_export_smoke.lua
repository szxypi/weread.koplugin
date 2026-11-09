-- Actual native menus, fork, SQLite settings, ZIP, CRE and exclusive files.
return function(plugin,count,flush,home,pump,assert_snapshot)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local ffi=require('ffi')
    local lfs=require('libs/libkoreader-lfs')
    local socket=require('socket')
    local Content=require('weread.lib.content')
    local Model=require('weread.lib.mp_export')
    local Export=require('weread.ui.mp_export')
    local tr=require('weread.lib.i18n').tr
    local settings,client=plugin.settings,plugin.client
    local parent=tonumber(ffi.C.getpid())
    local request,real_write=client.request,Model.write
    local original_doc=plugin.ui.document
    local original_cache=settings.cache_dir
    local book={book_id='MP_WXS_900099',title='合成公众号',cache_dir=settings.data_dir..'/moved-mp-export-cache'}
    local article={reviewId='export-fixture',title='合成文章：离线导出',createTime=1700000000}
    local article_dir=Content.mp_article_path(settings,book,article):match('^(.*)/[^/]+$')
    local asset_dir=article_dir..'/.weread-mp-export-fixture-assets'
    assert(require('util').makePath(asset_dir) or lfs.attributes(asset_dir,'mode')=='directory')
    local png=require('mime').unb64('iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAAXElEQVR4nO3PsQ0AQAzCwOy/9P8EKVIZJFNTnOctm2Vp/ziQATTIABpkAA06B7RAz2FpIANokAE0yAAatP5roC0gA2iQATTIABp0DmiBnsPSQAbQIANokAE0aPt/y1n0pl3lRNkAAAAASUVORK5CYII=')
    local function write(path,bytes)
        local file=assert(io.open(path,'wb'));assert(file:write(bytes));file:close()
    end
    local function read(path)
        local file=assert(io.open(path,'rb'));local bytes=file:read('*a');file:close();return bytes
    end
    write(asset_dir..'/img-0001.png',png)
    local body='<p id="intro">导出的合成正文 &amp; 保留文字。</p><p><strong>粗体测试</strong>和<em>斜体测试</em></p>'
        ..'<p><a href="#intro">返回开头</a><a href="https://example.invalid/article">原文链接</a></p>'
        ..'<p><img src=".weread-mp-export-fixture-assets/img-0001.png" alt="本机图片"/>'
        ..'<img src=".weread-mp-export-fixture-assets/img-0001.png"/>'
        ..'<img src="data:image/png;base64,'..require('mime').b64(png)..'"/>'
        ..'<img src="https://example.invalid/not-downloaded.png"/><img src="file:///private"/></p>'
        ..'<script>privateScript()</script><p onclick="bad()" style="background:url(file:///private)">结束文字。</p>'
    local source=Content.save_mp_article_html(settings,book,article,body)
    local source_bytes=read(source)
    book.mp_articles={article};book.progress=.25;book.pending_upload_position={chapter_uid=1,chapter_offset=3}
    local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
    local saved_before=client:json_encode(settings:get('books',{})[book.book_id])
    local writes_before=count('/web/book/read')
    local function close_result()
        Export.cancel(plugin)
        local top=UIManager:getTopmostVisibleWidget()
        if top and top~=plugin.ui and top.text then UIManager:close(top) end
    end
    Model.write=function(...)
        assert(tonumber(ffi.C.getpid())~=parent,'MP export ran on UI event loop')
        socket.sleep(.4);return real_write(...)
    end
    client.request=function() error('MP export attempted HTTP') end
    plugin:closeWeReadUI()
    plugin:showMPArticleList(book,{article})
    local old_list=assert(plugin._mp_article_list_view)
    plugin:showMPArticleList(book,{article})
    assert(plugin._mp_article_list_view~=old_list,'article list refresh retained old widget')
    for _,row in ipairs(old_list.item_table) do if row.text==tr('Export cached article') then row.callback() end end
    assert(not plugin._mp_export_menu,'old article list started export')
    local menu=assert(plugin._mp_article_list_view)
    local entry
    for _,row in ipairs(menu.item_table) do if row.text==tr('Export cached article') then entry=row end end
    assert(entry,'article export list entry missing');menu:onMenuSelect(entry)
    local picker_menu=assert(plugin._mp_export_menu)
    picker_menu:onMenuSelect(picker_menu.item_table[1])
    local picker=assert(plugin._mp_export_picker)
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-export-confirm.png')
    picker.ok_callback()
    local job=assert(plugin.mp_export_job);local path=job.output.path
    assert(plugin.mp_export_worker.job.pid~=parent,'export worker not forked')
    local heartbeat=false;UIManager:scheduleIn(.1,function() heartbeat=true end)
    pump(function() return heartbeat end);assert(plugin.mp_export_job,'export blocked native event loop')
    pump(function() return not plugin.mp_export_job end);flush()
    local result=assert(plugin._mp_export_result,'EPUB export failed')
    assert(result.text:find(tr('Open exported article'),1,true)==nil,'unexpected result fixture')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-export-success.png')
    local archive=require('weread.lib.source_archive').read(path,{
        mimetype=64,['EPUB/package.opf']=1024*1024,['EPUB/article.xhtml']=1024*1024,
        ['EPUB/images/image-1.png']=1024,['EPUB/images/image-2.png']=1024})
    assert(archive and archive.mimetype=='application/epub+zip','export archive unreadable')
    local xhtml=archive['EPUB/article.xhtml']
    assert(xhtml:find('导出的合成正文 &amp; 保留文字。',1,true) and xhtml:find('粗体测试',1,true),'article text lost')
    assert(xhtml:find('images/image-1.png',1,true) and xhtml:find('images/image-2.png',1,true)
        and archive['EPUB/images/image-1.png']==png and archive['EPUB/images/image-2.png']==png,'image packaging incorrect')
    assert(not xhtml:find('privateScript',1,true) and not xhtml:find('file:',1,true) and not xhtml:find('not-downloaded',1,true)
        and not xhtml:find('onclick',1,true) and not xhtml:find('data:image',1,true),'active/remote resource survived')
    assert(xhtml:find(tr('Image unavailable'),1,true),'missing image placeholder absent')
    local bitmap=assert(require('ui/renderimage'):renderImageData(archive['EPUB/images/image-1.png'],#png))
    assert(bitmap:getWidth()==64 and bitmap:getHeight()==32,'packed bitmap did not decode');bitmap:free()
    local generated=assert(require('document/documentregistry'):openDocument(path))
    assert(generated:loadDocument(),'exported EPUB did not load in CRE')
    generated:setFontFace('Noto Sans CJK SC');generated:setFontSize(Screen:scaleBySize(24));generated:render()
    assert(generated:getPageCount()>=1 and generated:getTextFromXPointer('/body'):find('导出的合成正文',1,true),'CRE text missing')
    local placed=false
    for y=16,Screen:getHeight()-16,16 do
        for x=16,Screen:getWidth()-16,16 do
            local image=generated:getImageFromPosition({x=x,y=y})
            if image then
                assert(image:getWidth()==64 and image:getHeight()==32,'CRE bitmap bytes did not decode')
                image:free();placed=true;break
            end
        end
        if placed then break end
    end
    assert(placed,'exported bitmap not placed in the native document')
    generated:close()
    local export_bytes=read(path)
    local open_file=plugin.openFile;local opened
    plugin.openFile=function(_self,target) opened=target end
    result.ok_callback();plugin.openFile=open_file
    assert(opened==path,'native result did not open accepted export')
    plugin.ui.document={file=source}
    local reader_entry
    for _,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Export article to EPUB') then reader_entry=item end end
    assert(reader_entry,'current MP reader export action missing');reader_entry.callback()
    assert(plugin._mp_export_picker,'current article not identified at custom cache root');Export.cancel(plugin)
    plugin.ui.document=original_doc
    Export.list(plugin,book,{article,article})
    local ambiguous=assert(plugin._mp_export_menu)
    assert(#ambiguous.item_table==1 and ambiguous.item_table[1].select_enabled~=false,'duplicate same-identity article not coalesced')
    Export.cancel(plugin)
    Export.show(plugin,book,article);local dismissed=assert(plugin._mp_export_picker)
    UIManager:close(dismissed);dismissed.ok_callback()
    assert(not plugin.mp_export_job and not plugin._mp_export_picker,'native-closed picker began export')
    -- Saved EPUB caches are copied byte-for-byte, with no reflow or metadata rewrite.
    local legacy={reviewId='legacy',title='合成旧格式'}
    book.mp_articles={article,legacy}
    local legacy_path=Content.mp_article_legacy_path(settings,book,legacy):gsub('%.html$','.epub')
    write(legacy_path,export_bytes)
    assert(Export.start(plugin,book,legacy));local copied=plugin.mp_export_job.output.path
    pump(function() return not plugin.mp_export_job end);assert(plugin._mp_export_result and read(copied)==export_bytes,'legacy EPUB bytes changed');close_result()
    -- Aborted and stale work cannot leave a partial file or replace older exports.
    for _,change in ipairs({'dismiss','account','session','suspend','close_ui','close_document','source','storage','oversized','image_symlink'}) do
        if change=='image_symlink' then
            os.remove(asset_dir..'/img-0001.png');assert(lfs.link(source,asset_dir..'/img-0001.png',true))
        end
        assert(Export.start(plugin,book,article));local partial=plugin.mp_export_job.output.path
        if change=='dismiss' then plugin.busy_message:onTapClose()
        elseif change=='account' then plugin:onWeReadAccountChanged()
        elseif change=='session' then plugin._reader_session_gen=plugin._reader_session_gen+1
        elseif change=='suspend' then plugin:onSuspend();plugin:onResume()
        elseif change=='close_ui' then plugin:closeWeReadUI()
        elseif change=='close_document' then
            local cancel=plugin.cancelMPArticleExport
            plugin.cancelMPArticleExport=function(self) cancel(self);error('stop after MP cleanup',0) end
            local ok,err=pcall(require('weread.lib.reader_lifecycle').onCloseDocument,plugin)
            plugin.cancelMPArticleExport=cancel;assert(not ok and err=='stop after MP cleanup','close missed MP export')
        elseif change=='source' then write(source,source_bytes..' ')
        elseif change=='storage' then
            local output=plugin.mp_export_job.output;output.accept=function() return false end
        elseif change=='oversized' then
            -- A start snapshot followed by excessive resource growth is rejected.
            local image=assert(io.open(asset_dir..'/img-0001.png','wb'));image:seek('set',Model.MAX_IMAGE);image:write('x');image:close()
        end
        pump(function() return not plugin.mp_export_job end);flush()
        if change=='image_symlink' then
            assert(plugin._mp_export_result,'unavailable symlink should become a placeholder, not read another file')
            local safe=require('weread.lib.source_archive').read(partial,{['EPUB/article.xhtml']=1024*1024})
            assert(safe and not safe['EPUB/article.xhtml']:find('src="images/image-2.png"',1,true),'symlink target was packed')
            close_result();os.remove(partial)
        else assert(not lfs.attributes(partial) and not plugin._mp_export_result,change..' retained partial export');close_result() end
        write(source,source_bytes)
        if change=='oversized' or change=='image_symlink' then os.remove(asset_dir..'/img-0001.png');write(asset_dir..'/img-0001.png',png) end
    end
    assert(read(path)==export_bytes and read(source)==source_bytes and read(asset_dir..'/img-0001.png')==png,'export changed earlier output or source')
    settings.cache_dir=settings.data_dir;plugin.ui.document={file=path}
    assert(plugin:detectWeReadBook()==nil,'export under custom cache root gained a cloud identity')
    plugin.ui.document=original_doc;settings.cache_dir=original_cache
    local order_only=assert_snapshot(saved_before,settings:get('books',{})[book.book_id],'export changed saved progress/intent/cache')
    client.request=request;Model.write=real_write
    assert(count('/web/book/read')==writes_before,'export sent reading data')
    local report={result='PASS',synthetic_only=true,record_json_order_only_changed=order_only,native_list_picker=true,native_reader_entry=true,
        native_confirm_and_result=true,background_process=true,ui_heartbeat=true,custom_cache_root=true,
        packaged_bitmap_decoded=true,native_document_bitmap_placed=true,
        replaced_article_list_callback_ignored=true,
        cre_opened_export=true,unicode_text_preserved=true,cached_images_packed=true,duplicate_images_shared=true,
        embedded_bitmap_packed=true,missing_images_marked=true,passive_markup=true,legacy_epub_bytes_unchanged=true,
        duplicate_same_identity_coalesced=true,native_closed_picker_ignored=true,
        source_and_images_unchanged=true,existing_export_preserved=true,cancel_and_stale_cleanup=true,
        account_session_suspend_close_guards=true,changed_source_rejected=true,failed_accept_clean=true,
        oversized_image_rejected=true,image_symlink_not_followed=true,export_cloud_identity_excluded=true,
        local_progress_and_pending_intent_unchanged=true,network_calls=0,reading_data_writes=0}
    write(home..'/../evidence/mp-export.json',client:json_encode(report))
    print('PASS: native cached MP EPUB export -> real fork/ZIP/CRE, Unicode/bitmaps/links/placeholders/legacy copy; cancellation, source/storage/size/symlink protections and zero HTTP')
end
