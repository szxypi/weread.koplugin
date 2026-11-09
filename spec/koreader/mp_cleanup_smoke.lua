-- Offline native preview, kernel flock, real deletion batches and retained notes.
return function(plugin,count,flush,home,pump)
    local UIManager=require('ui/uimanager');local Screen=require('device').screen
    local lfs=require('libs/libkoreader-lfs');local ffi=require('ffi')
    local Model=require('weread.lib.mp_cache_cleanup');local Cleanup=require('weread.ui.mp_cache_cleanup')
    local Identity=require('weread.lib.mp_cache_identity');local Versions=require('weread.lib.mp_cache_versions')
    local settings,client=plugin.settings,plugin.client;local parent_pid=tonumber(ffi.C.getpid())
    local book={book_id='MP_WXS_900087',title='合成缓存清理',cache_dir=settings.data_dir..'/mp-cleanup',progress=.4,pending_upload_position={offset=13}}
    local article={reviewId='cleanup-fixture',title='保留当前正文和笔记'};book.mp_articles={article}
    local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
    local key=assert(Identity.key(book,article));local base=assert(Identity.prepare(book.cache_dir,key));local parent=base:match('^(.*)/[^/]+$')
    local function read(path) local file=assert(io.open(path,'rb'));local data=file:read('*a');file:close();return data end
    local function write(path,data) local file=assert(io.open(path,'wb'));assert(file:write(data));file:close() end
    local function generation(nonce,n)
        local name='.weread-mp-'..key..'-assets-'..string.rep(nonce,16)
        assert(require('util').makePath(parent..'/'..name..'/images'))
        for index=1,n do write(parent..'/'..name..'/images/'..string.format('img-%04d.png',index),'synthetic-bitmap-'..nonce..'-'..index) end
        return name
    end
    local old_images=generation('1',1);local current_images=generation('2',1);local orphan=generation('3',20)
    local active='article-2222222222222222.html';local active_path=parent..'/'..active
    write(base,Identity.marker(key)..'<html><body><p>旧版正文</p><img src="'..old_images..'/images/img-0001.png"/></body></html>')
    write(active_path,Identity.marker(key)..'<html><body><p>保留当前正文</p><img src="'..current_images..'/images/img-0001.png"/></body></html>')
    local active_body=read(active_path);write(parent..'/current','weread-mp-current-v1\n'..active..'\n')
    local notes=require('docsettings'):open(base);notes:saveSetting('annotations',{{text='清理后仍保留的笔记',note='合成笔记'}})
    local sidecar=assert(notes:flush())..'/'..notes.sidecar_filename;local old_notes=read(sidecar)
    local requests=count('/web/mp/content')+count('/web/mp/articles')+count('/api/agent/gateway')
    local writes=count('/web/book/read');local renewals=count('/web/login/renewal')
    local old_scan,old_step=Model.scan,Model.step
    Model.scan=function(...)
        assert(tonumber(ffi.C.getpid())~=parent_pid,'cache scan blocked UI thread')
        require('socket').sleep(.25);return old_scan(...)
    end
    local function parent_step(...)
        assert(tonumber(ffi.C.getpid())==parent_pid,'background child could delete cache after owner changed')
        return old_step(...)
    end
    Model.step=parent_step
    local protected=old_scan(book.cache_dir,key,base)
    assert(#Model.targets(protected).generations==0 and not pcall(Model.targets,protected,'article.html'),'open article was not protected on the actual filesystem')
    local function close_info()
        local top=UIManager:getTopmostVisibleWidget();if top~=plugin.ui and top.text then UIManager:close(top) end
    end
    local function preview()
        assert(Cleanup.show(plugin,book,article));pump(function() return plugin._mp_cleanup_menu or not plugin.mp_cleanup_job end)
        return assert(plugin._mp_cleanup_menu,'cleanup preview failed')
    end
    local heartbeat=false
    assert(Cleanup.show(plugin,book,article));local first=plugin.mp_cleanup_job
    UIManager:scheduleIn(.1,function() heartbeat=plugin.mp_cleanup_job==first and plugin.busy_message~=nil end)
    pump(function() return plugin._mp_cleanup_menu or not plugin.mp_cleanup_job end)
    local menu=assert(plugin._mp_cleanup_menu);assert(heartbeat and #menu.item_table==3,'preview blocked UI or missed saved versions')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-cleanup-preview.png')
    menu.item_table[1].callback();local dialog=assert(plugin._mp_cleanup_confirmation)
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-cleanup-confirm.png')
    dialog.cancel_callback();UIManager:close(dialog)
    assert(lfs.attributes(parent..'/'..orphan,'mode')=='directory' and not Model.locked(book.cache_dir,key),'cancelled confirmation deleted or locked cache')
    -- Stop after one real batch; the dialog reports actual partial work.
    local steps=0
    Model.step=function(job)
        steps=steps+1;local ok,reason=parent_step(job)
        if steps==1 then UIManager:scheduleIn(.05,function() assert(plugin.busy_message:onAnyKeyPressed()) end) end
        return ok,reason
    end
    menu.item_table[1].callback();plugin._mp_cleanup_confirmation.ok_callback()
    pump(function() return not plugin.mp_cleanup_job end);flush()
    assert(steps==1 and not Model.locked(book.cache_dir,key),'cancel did not stop batch/release kernel lock')
    local left=0;for name in lfs.dir(parent..'/'..orphan..'/images') do if name~='.' and name~='..' then left=left+1 end end
    assert(left==4 and read(base):find('旧版正文',1,true) and read(active_path)==active_body and read(sidecar)==old_notes,'partial cleanup touched text/notes or counts wrong')
    assert(UIManager:getTopmostVisibleWidget().text:find('16',1,true),'native partial result omitted actual removed file count')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-cleanup-stopped.png')
    close_info();Model.step=parent_step
    menu=preview();menu.item_table[1].callback();plugin._mp_cleanup_confirmation.ok_callback()
    pump(function() return not plugin.mp_cleanup_job end);close_info()
    assert(not lfs.symlinkattributes(parent..'/'..orphan) and lfs.attributes(parent..'/'..old_images,'mode')=='directory'
        and lfs.attributes(parent..'/'..current_images,'mode')=='directory','unused cleanup deleted retained images')
    -- Deleting an explicitly selected old body keeps its KOReader sidecar.
    menu=preview();local old_row
    for _,row in ipairs(menu.item_table) do if row.mandatory==require('weread.lib.i18n').tr('Remove old version') then old_row=row end end
    assert(old_row);old_row.callback()
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-cleanup-remove-version.png')
    plugin._mp_cleanup_confirmation.ok_callback()
    pump(function() return not plugin.mp_cleanup_job end);close_info()
    assert(not lfs.symlinkattributes(base) and not lfs.symlinkattributes(parent..'/'..old_images)
        and read(sidecar)==old_notes and read(active_path)==active_body and Versions.resolve(book.cache_dir,key)==active_path,'old cleanup damaged active cache or notes')
    assert(settings:get('books',{})[book.book_id].progress==.4 and settings:get('books',{})[book.book_id].pending_upload_position.offset==13,'cleanup changed progress/pending intent')
    -- Persistent lock files are reusable, and live locks block downloads.
    local lock=assert(Model.acquire(book.cache_dir,key));assert(Model.locked(book.cache_dir,key))
    assert(not require('weread.lib.mp_download_stage').create(book.cache_dir,key),'download started during cleanup')
    lock:release();assert(not Model.locked(book.cache_dir,key) and lfs.attributes(parent..'/.mp-cleanup','mode')=='file','released marker blocked future operation')
    local stage=assert(require('weread.lib.mp_download_stage').create(book.cache_dir,key));stage:cleanup()
    -- A killed worker's actual descriptor releases the kernel lock automatically.
    local worker=require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=client}
    assert(worker:start(function()
        local acquired=assert(Model.acquire(book.cache_dir,key));assert(acquired.fd)
        write(parent..'/lock-held','synthetic');require('socket').sleep(10);return {ok=true}
    end,function() error('lock owner unexpectedly completed') end))
    local pid=assert(worker.job).pid
    pump(function() return lfs.attributes(parent..'/lock-held','mode')=='file' and Model.locked(book.cache_dir,key) end)
    assert(not worker.runner.done(pid),'lock owner was not live');worker:cancel()
    pump(function() return worker.runner.done(pid) and not Model.locked(book.cache_dir,key) end);os.remove(parent..'/lock-held')
    -- A stale preview cannot delete after the active source changes.
    local unused=generation('4',1);menu=preview();menu.item_table[1].callback();dialog=plugin._mp_cleanup_confirmation
    local replacement=parent..'/replacement';write(replacement,active_body..'<!-- changed -->');assert(os.rename(replacement,active_path))
    dialog.ok_callback();pump(function() return not plugin.mp_cleanup_job end);close_info()
    assert(lfs.attributes(parent..'/'..unused,'mode')=='directory' and not Model.locked(book.cache_dir,key),'stale preview removed new cache state')
    -- Native suspend cancels a preview, including its old confirmation callback.
    menu=preview();menu.item_table[1].callback();dialog=plugin._mp_cleanup_confirmation;plugin:onSuspend();dialog.ok_callback()
    assert(not plugin.mp_cleanup_job and lfs.attributes(parent..'/'..unused,'mode')=='directory','suspended confirmation deleted files')
    Model.scan=old_scan;Model.step=old_step;plugin:closeWeReadUI();close_info()
    assert(UIManager:getTopmostVisibleWidget()==plugin.ui and not Model.locked(book.cache_dir,key),'cleanup left overlay or lock')
    assert(count('/web/mp/content')+count('/web/mp/articles')+count('/api/agent/gateway')==requests
        and count('/web/book/read')==writes and count('/web/login/renewal')==renewals,'offline cleanup contacted account API')
    local report={result='PASS',synthetic_only=true,actual_background_scan=true,ui_heartbeat=true,
        native_preview_confirmation=true,confirmation_cancel_no_delete=true,batch_cancel_exact_partial_count=true,
        referenced_images_preserved=true,open_article_protected=true,parent_only_mutation=true,old_version_explicit_delete=true,current_cache_preserved=true,sidecar_bytes_preserved=true,
        progress_pending_preserved=true,kernel_lock_blocks_downloads=true,released_marker_reusable=true,
        actual_owner_death_releases_lock=true,stale_preview_no_delete=true,suspend_old_confirmation_no_delete=true,
        returns_to_reader=true,account_reads=0,account_data_writes=0,credential_renewals=0}
    write(home..'/../evidence/mp-cleanup.json',client:json_encode(report))
    print('PASS: native offline article cleanup -> background reachability, explicit confirmation, partial cancel, retained current/notes, kernel lock/download gate and owner-death recovery')
end
