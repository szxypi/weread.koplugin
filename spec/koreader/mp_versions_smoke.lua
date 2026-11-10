-- Native cache actions, actual fork/HTTP, immutable HTML and KOReader sidecars.
return function(plugin,count,flush,home,pump,control)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local lfs=require('libs/libkoreader-lfs')
    local Content=require('weread.lib.content')
    local Identity=require('weread.lib.mp_cache_identity')
    local Versions=require('weread.lib.mp_cache_versions')
    local Actions=require('weread.ui.mp_article_actions')
    local DocSettings=require('docsettings')
    local tr=require('weread.lib.i18n').tr
    local settings,client=plugin.settings,plugin.client
    local book={book_id='MP_WXS_900088',title='合成文章版本',cache_dir=settings.data_dir..'/mp-versions',progress=.2,pending_upload_position={offset=7}}
    local article={reviewId='background-fixture',title='保留笔记的合成文章'};book.mp_articles={article}
    local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
    local original_cache=settings:get('cache',{});local cache={};for k,v in pairs(original_cache) do cache[k]=v end
    cache.download_mp_images=true;settings:set('cache',cache);settings:flush()
    local open=plugin.openFile;local opened
    plugin.openFile=function(_self,path) opened=path end
    local writes,renewals=count('/web/book/read'),count('/web/login/renewal')
    local function read(path) local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close();return raw end
    local function write(path,raw) local file=assert(io.open(path,'wb'));assert(file:write(raw));file:close() end
    local function info_close()
        local top=UIManager:getTopmostVisibleWidget();if top~=plugin.ui and top.text then UIManager:close(top) end
    end
    local function wait() pump(function() return not plugin.mp_download_job end);flush() end
    local function sidecar(path,text)
        local data=DocSettings:open(path)
        data:saveSetting('last_xpointer','/body/DocFragment[1]/body/p[1]')
        data:saveSetting('annotations',{{text=text,note='保留的合成笔记',pos0='/body/p[1]',pos1='/body/p[2]'}})
        local dir=assert(data:flush());return dir..'/'..data.sidecar_filename
    end
    local function refreshed()
        opened=nil;assert(Actions.refresh(plugin,book,article));local dialog=assert(plugin._mp_refresh_confirmation)
        dialog.ok_callback();return plugin.mp_download_job
    end
    control{mp_article_version=1,match='',times=0,delay=0}
    assert(plugin:downloadMPArticleAndRead(book,article));wait()
    local original=assert(opened);local original_body=read(original);local original_sidecar=sidecar(original,'旧版划线')
    local original_metadata=read(original_sidecar)
    local original_bitmap=assert(original_body:match('src="([^"<>]+/images/img%-0001%.png)"'))
    local parent=original:match('^(.*)/[^/]+$');local bitmap=read(parent..'/'..original_bitmap)
    -- The article-list toolbar is keyboard accessible and reading stays one tap.
    plugin:showMPArticleList(book,book.mp_articles)
    local found
    for _,row in ipairs(plugin._mp_article_list_view.item_table) do if row.text==tr('Article cache and versions') then found=row end end
    assert(found,'native article cache toolbar missing');found.callback()
    assert(plugin._mp_cache_picker);plugin._mp_cache_picker.item_table[1].callback()
    local actions=assert(plugin._mp_actions_menu);assert(actions.item_table[1].text==tr('Read cached article'))
    actions.item_table[2].callback();local dialog=assert(plugin._mp_refresh_confirmation)
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-refresh-confirm.png')
    local reads=count('/web/mp/content');dialog.cancel_callback();UIManager:close(dialog)
    assert(count('/web/mp/content')==reads and not plugin.mp_download_job,'cancelled refresh sent a request')
    control{mp_article_version=2}
    refreshed()
    books=settings:get('books',{});books[book.book_id].progress=.6;books[book.book_id].pending_upload_position={offset=17}
    settings:set('books',books);settings:flush();wait()
    local newest=assert(opened);local newest_body=read(newest)
    assert(newest~=original and newest:match('/article%-[a-f0-9]+%.html$'),'refresh reused original sidecar path')
    assert(Content.mp_article_cached_path(settings,book,article)==newest and newest_body:find('合成版本 2',1,true),'active version not selected')
    assert(read(original)==original_body and read(original_sidecar)==original_metadata and read(parent..'/'..original_bitmap)==bitmap,'refresh changed old body, annotations or bitmap')
    assert(settings:get('books',{})[book.book_id].progress==.6 and settings:get('books',{})[book.book_id].pending_upload_position.offset==17,'refresh overwrote newer local progress or intent')
    local new_data=DocSettings:open(newest)
    assert(not new_data:readSetting('last_xpointer') and not new_data:readSetting('annotations'),'new version inherited stale coordinates')
    local new_sidecar=sidecar(newest,'新版划线');local new_metadata=read(new_sidecar)
    for _,entry in ipairs({{path=original,text='合成版本 1'},{path=newest,text='合成版本 2'}}) do
        local doc=assert(require('document/documentregistry'):openDocument(entry.path));assert(doc:loadDocument());doc:render()
        assert((doc:getTextFromXPointer('/html/body') or doc:getTextFromXPointer('/body')):find(entry.text,1,true),'CRE opened wrong revision');doc:close()
    end
    plugin:closeWeReadUI();assert(Actions.history(plugin,book,article));local menu=assert(plugin._mp_versions_menu)
    assert(#menu.item_table==2 and menu.item_table[1].mandatory==tr('Current cache'),'saved versions not listed')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-saved-versions.png')
    opened=nil;menu.item_table[2].callback();assert(opened==original and DocSettings:open(opened):readSetting('annotations')[1].text=='旧版划线','old version lost its notes')
    plugin:closeWeReadUI()
    -- Images of the new immutable path remain exportable.
    local output=assert(require('weread.lib.notes_export_file').create(settings.data_dir..'/mp-versions-export','Version','epub'))
    local result=require('weread.lib.mp_export').write({path=newest,identity=lfs.symlinkattributes(newest),book=book,article=article},output,{})
    assert(result.ok and result.images==1 and result.missing==0 and output:accept(result.bytes),'new-version images failed EPUB export')
    -- The current-article export menu must use the opened old version, not latest.
    local Export=require('weread.ui.mp_export');local Common=require('weread.ui.common')
    local export_path
    local host={settings={data_dir=settings.data_dir..'/mp-versions-context',get=function(_self,...) return settings:get(...) end},
        client=client,library_db=plugin.library_db,ui={document={file=original}},_reader_session_gen=1,
        detectWeReadBook=function() return book.book_id end,closeWeReadUI=function(self) Export.cancel(self);self.discovery_epoch=(self.discovery_epoch or 0)+1 end,
        showBusy=Common.showBusy,closeBusy=Common.closeBusy,refreshUI=Common.refreshUI,showInfo=Common.showInfo,
        openFile=function(_self,path) export_path=path end}
    assert(Export.current(host));host._mp_export_picker.ok_callback();pump(function() return not host.mp_export_job end)
    assert(host._mp_export_result,'historical current-article export failed');host._mp_export_result.ok_callback()
    local members=assert(require('weread.lib.source_archive').read(assert(export_path),{['EPUB/article.xhtml']=1024*1024}))
    assert(members['EPUB/article.xhtml']:find('合成版本 1',1,true) and not members['EPUB/article.xhtml']:find('合成版本 2',1,true),'historical export selected current version')
    Export.cancel(host)
    -- Cancellation and a selector rename failure keep the complete prior version.
    local model=require('weread.lib.mp_download');local original_write=model.write
    model.write=function(...) local receipt=original_write(...);require('socket').sleep(.4);return receipt end
    control{mp_article_version=3,match='',times=0,delay=0};reads=count('/web/mp/content')
    local job=assert(refreshed());local pending=job.stage.directory
    pump(function() return count('/web/mp/content')==reads+1 end)
    assert(plugin.busy_message:onAnyKeyPressed());wait();pump(function() return not lfs.symlinkattributes(pending) end)
    model.write=original_write
    assert(not opened and Versions.resolve(book.cache_dir,Identity.key(book,article))==newest,'cancel switched selection')
    local rename=os.rename
    rawset(os,'rename',function(from,to) if to==parent..'/current' then return nil,'injected selector failure' end;return rename(from,to) end)
    job=assert(refreshed());wait();rawset(os,'rename',rename);info_close()
    assert(not opened and Versions.resolve(book.cache_dir,Identity.key(book,article))==newest
        and not lfs.symlinkattributes(parent..'/'..job.stage.version_name) and not lfs.symlinkattributes(job.stage.directory),'failed selector publication leaked or switched complete version')
    assert(read(newest)==newest_body and read(new_sidecar)==new_metadata,'failed refresh changed previous version or sidecar')
    -- An external selector replacement is not overwritten by a delayed result.
    model.write=function(...) require('socket').sleep(.3);return original_write(...) end
    assert(refreshed());local selector=read(parent..'/current');reads=count('/web/mp/content')
    local other_name='article-ffffffffffffffff.html';local other=parent..'/'..other_name
    write(other,newest_body)
    assert(Versions.publish(assert(Versions.capture(book.cache_dir,Identity.key(book,article))),other_name))
    wait();info_close();model.write=original_write
    assert(count('/web/mp/content')==reads+1,'external-selection scene did not finish exactly one body GET')
    assert(not opened and Versions.resolve(book.cache_dir,Identity.key(book,article))==other,'external selection overwritten')
    write(parent..'/current.restore',selector);assert(os.rename(parent..'/current.restore',parent..'/current'));os.remove(other)
    -- Corrupt and symbolic-link selectors refuse new HTTP and stale fallback.
    reads=count('/web/mp/content');write(parent..'/current','broken')
    assert(not plugin:downloadMPArticleAndRead(book,article));info_close()
    assert(not Content.mp_article_cached_path(settings,book,article) and count('/web/mp/content')==reads,'corrupt selector fell back or sent HTTP')
    os.remove(parent..'/current');write(parent..'/outside-selector',selector);assert(lfs.link(parent..'/outside-selector',parent..'/current',true))
    assert(not plugin:downloadMPArticleAndRead(book,article));info_close()
    assert(read(parent..'/outside-selector')==selector and count('/web/mp/content')==reads,'selector symlink followed')
    os.remove(parent..'/current');assert(os.rename(parent..'/outside-selector',parent..'/current'))
    local maximum=Versions.MAX_VERSIONS;Versions.MAX_VERSIONS=2
    assert(not plugin:downloadMPArticleAndRead(book,article));Versions.MAX_VERSIONS=maximum;info_close()
    assert(count('/web/mp/content')==reads,'version capacity dispatched download')
    -- Refreshing an unambiguous legacy title cache keeps its sidecar accessible.
    local legacy={reviewId='cache-fixture-c',title='旧格式文章'};book.mp_articles={article,legacy}
    books=settings:get('books',{});books[book.book_id].mp_articles=book.mp_articles;settings:set('books',books);settings:flush()
    local legacy_path=Content.mp_article_legacy_path(settings,book,legacy)
    write(legacy_path,'<html><body><p>保留旧格式正文</p></body></html>')
    local legacy_sidecar=sidecar(legacy_path,'旧格式笔记');local legacy_metadata=read(legacy_sidecar)
    assert(Actions.refresh(plugin,book,legacy));plugin._mp_refresh_confirmation.ok_callback();wait()
    assert(opened~=legacy_path and read(legacy_sidecar)==legacy_metadata and read(legacy_path):find('保留旧格式正文',1,true),'legacy refresh changed source or sidecar')
    plugin:closeWeReadUI();assert(Actions.history(plugin,book,legacy));menu=plugin._mp_versions_menu
    assert(#menu.item_table==2,'legacy version missing from history');opened=nil;menu.item_table[2].callback()
    pump(function() return plugin._mp_records_menu~=nil or plugin.mp_records_job==nil end)
    assert(not opened and plugin._mp_records_menu,'legacy history bypassed record protection')
    local recovery=assert(require('weread.lib.mp_records_db').new(settings,plugin.library_db:accountKey()))
    local legacy_key=assert(Identity.key(book,legacy));local snapshots=assert(recovery:list(legacy_key))
    assert(#snapshots>0 and read(legacy_sidecar)==legacy_metadata,'legacy records were not preserved before selection')
    local selected
    for index,row in ipairs(snapshots) do
        if row.valid then
            local data=require('weread.lib.mp_record_data').record(assert(recovery:get(legacy_key,row.id)))
            if data.annotations and data.annotations[1].text=='旧格式笔记' then selected=index;break end
        end
    end
    assert(selected);plugin._mp_records_menu.item_table[selected].callback();assert(plugin._mp_records_confirmation).ok_callback()
    pump(function() return plugin.mp_records_job==nil end)
    assert(opened and opened~=legacy_path and Versions.contains(book.cache_dir,legacy_key,opened)
        and DocSettings:open(opened):readSetting('annotations')[1].text=='旧格式笔记'
        and read(legacy_path):find('保留旧格式正文',1,true) and read(legacy_sidecar)==legacy_metadata,
        'confirmed legacy recovery lost its original body, sidecar, or selected record')
    plugin:closeWeReadUI();assert(Actions.refresh(plugin,book,article));dialog=plugin._mp_refresh_confirmation
    reads=count('/web/mp/content');plugin:onSuspend();dialog.ok_callback()
    assert(not plugin._mp_refresh_confirmation and count('/web/mp/content')==reads,'suspended confirmation restarted refresh')
    plugin:onResume();dialog.ok_callback()
    assert(not plugin.source_position.pauses.suspend and count('/web/mp/content')==reads,'resume revived stale refresh confirmation')
    plugin.openFile=open;plugin:closeWeReadUI();settings:set('cache',original_cache);settings:flush()
    assert(UIManager:getTopmostVisibleWidget()==plugin.ui and count('/web/book/read')==writes and count('/web/login/renewal')==renewals,'versions left overlay or wrote cloud data')
    local report={result='PASS',synthetic_only=true,actual_background_http=true,native_actions_and_confirmation=true,
        immutable_html_and_images=true,old_sidecar_bytes_preserved=true,new_version_has_no_old_coordinates=true,
        native_history_opens_old_notes_path=true,cre_reads_distinct_versions=true,new_version_epub_images=true,historical_current_article_export=true,fresh_local_progress_intent_preserved=true,
        cancel_and_failed_selector_keep_prior=true,failed_publication_cleans_new_files=true,external_selection_preserved=true,
        corrupt_and_symlink_selector_no_http=true,version_capacity_no_http=true,legacy_body_and_sidecar_preserved=true,
        legacy_history_requires_explicit_recovery=true,legacy_recovery_opens_independent_notes_copy=true,
        stale_suspend_confirmation_no_http=true,returns_to_reader=true,account_data_writes=0,credential_renewals=0}
    write(home..'/../evidence/mp-versions.json',client:json_encode(report))
    print('PASS: article refresh -> immutable versions, native menus, old/new DocSettings, CRE, EPUB images and selector failure/cancellation boundaries')
end
