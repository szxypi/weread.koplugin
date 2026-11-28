-- Actual inherited flock, surviving writer, ownership records and native repair.
return function(plugin,count,flush,home,pump)
    local UIManager=require('ui/uimanager');local Screen=require('device').screen
    local ffi=require('ffi');local lfs=require('libs/libkoreader-lfs')
    local Stage=require('weread.lib.mp_download_stage');local Model=require('weread.lib.mp_download_recovery')
    local Recovery=require('weread.ui.mp_download_recovery');local Cleanup=require('weread.lib.mp_cache_cleanup')
    local Content=require('weread.lib.content');local Identity=require('weread.lib.mp_cache_identity')
    local Versions=require('weread.lib.mp_cache_versions');local tr=require('weread.lib.i18n').tr
    local settings,client=plugin.settings,plugin.client;local parent_pid=tonumber(ffi.C.getpid())
    local book={book_id='MP_WXS_900086',title='合成暂存修复',cache_dir=settings.data_dir..'/mp-recovery',progress=.35,pending_upload_position={offset=19}}
    local article={reviewId='recovery-fixture',title='暂存修复测试文章'};book.mp_articles={article}
    local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
    local key=assert(Identity.key(book,article));local base=assert(Identity.prepare(book.cache_dir,key));local parent=base:match('^(.*)/[^/]+$')
    local function read(path) local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close();return raw end
    local function write(path,raw) local file=assert(io.open(path,'wb'));assert(file:write(raw));file:close() end
    local orphan='.weread-mp-'..key..'-assets-'..string.rep('d',16)
    assert(require('util').makePath(parent..'/'..orphan..'/images'));write(parent..'/'..orphan..'/images/img-0001.png','synthetic orphan')
    local saved=Content.render_mp_article_html(article,'<p>保留已保存正文</p>',key);write(base,saved)
    local notes=require('docsettings'):open(base);notes:saveSetting('annotations',{{text='保留的划线',note='合成笔记'}})
    local sidecar=assert(notes:flush())..'/'..notes.sidecar_filename;local metadata=read(sidecar)
    local http=count('/web/mp/content')+count('/web/mp/articles')+count('/api/agent/gateway')
    local writes,renewals=count('/web/book/read'),count('/web/login/renewal')
    local old_scan=Model.scan
    Model.scan=function(...)
        assert(tonumber(ffi.C.getpid())~=parent_pid,'recovery scan occupied UI process')
        require('socket').sleep(.2);return old_scan(...)
    end
    local function drop_creator(stage)
        stage:close()
        -- Close without LOCK_UN: another process still owns the inherited open
        -- description. This models the descriptor effect of creator exit.
        if stage.lease then assert(ffi.C.close(stage.lease.fd)==0);stage.lease.fd=nil;stage.lease=nil end
    end
    local function row(label)
        for _i,item in ipairs(assert(plugin._mp_recovery_view).item_table) do if item.mandatory==tr(label) then return item end end
    end
    local function inspect()
        assert(Recovery.show(plugin,book,article));pump(function() return plugin._mp_recovery_view or not plugin.mp_recovery_job end)
        return assert(plugin._mp_recovery_view,'recovery inspection failed')
    end
    local function finish() pump(function() return not plugin.mp_recovery_job end);flush();return assert(plugin._mp_recovery_result,'repair result missing') end
    local stage=assert(Stage.create(book.cache_dir,key,{preserve=true}))
    assert(stage.lease and stage.lease:read(4096):find(key,1,true),'durable ownership receipt missing')
    assert(stage.output:write(Content.render_mp_article_html(article,'<p>未发布正文</p>',key)) and stage.output:sync())
    write(stage.directory..'/images/img-0001.png','partial synthetic bitmap')
    local pending=stage.directory;local receipt=stage.lease.path
    local writer=require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=client}
    assert(writer:start(function()
        while true do assert(stage.output:write('<!-- live writer -->'));assert(stage.output:sync());require('socket').sleep(.15) end
    end,function() error('writer unexpectedly returned') end))
    local pid=assert(writer.job).pid
    drop_creator(stage);local before=lfs.attributes(stage.output.path,'size')
    pump(function() return lfs.attributes(stage.output.path,'size')>before end)
    assert(not writer.runner.done(pid),'inherited writer was not live')
    local unknown='.mp-pending-'..string.rep('f',16);local unknown_path=parent..'/'..unknown
    assert(lfs.mkdir(unknown_path));write(unknown_path..'/personal.txt','preserved unknown content')
    local heartbeat=false
    assert(Recovery.show(plugin,book,article));local request=plugin.mp_recovery_job
    UIManager:scheduleIn(.1,function() heartbeat=plugin.mp_recovery_job==request and plugin.busy_message~=nil end)
    pump(function() return plugin._mp_recovery_view or not plugin.mp_recovery_job end)
    assert(heartbeat and row('In use') and row('In use').select_enabled==false and row('Ownership unknown').select_enabled==false,
        'live inherited lease did not protect both mutation paths')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-recovery-active.png')
    assert(lfs.attributes(pending,'mode')=='directory' and read(receipt):find(key,1,true),'active inspection touched temporary data')
    writer:cancel();pump(function() return writer.runner.done(pid) end)
    inspect();assert(row('Interrupted download'),'reaped writer did not become an owned interrupted download')
    row('Interrupted download').callback();local dialog=assert(plugin._mp_recovery_confirmation)
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-recovery-clean-confirm.png')
    dialog.cancel_callback();UIManager:close(dialog);assert(lfs.attributes(pending,'mode')=='directory','cancelled confirmation deleted temporary data')
    row('Interrupted download').callback();plugin._mp_recovery_confirmation.ok_callback();finish()
    assert(not lfs.symlinkattributes(pending) and not lfs.symlinkattributes(receipt) and read(base)==saved and read(sidecar)==metadata,'owned repair touched saved data or left its record')
    Recovery.cancel(plugin)
    inspect();assert(row('Ownership unknown'));row('Ownership unknown').callback();dialog=assert(plugin._mp_recovery_confirmation)
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-recovery-quarantine-confirm.png')
    dialog.ok_callback();local result=finish()
    assert(result.text:find(tr('Download quarantined. No content was deleted or space freed. Its images are protected. You can restore it from this list.'),1,true),'quarantine claimed deletion or missing restoration')
    local quarantine=parent..'/.mp-quarantine-pending-'..string.rep('f',16)
    assert(not lfs.symlinkattributes(unknown_path) and read(quarantine..'/personal.txt')=='preserved unknown content','unknown content not preserved')
    local gc=Cleanup.scan(book.cache_dir,key,plugin.ui.document.file)
    assert(gc.quarantined and #Cleanup.targets(gc).generations==0 and lfs.attributes(parent..'/'..orphan,'mode')=='directory','quarantine lost associated image protection')
    result.ok_callback();pump(function() return plugin._mp_recovery_view or not plugin.mp_recovery_job end)
    assert(row('Quarantined'));UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-recovery-quarantined.png')
    row('Quarantined').callback();plugin._mp_recovery_confirmation.ok_callback();finish()
    assert(read(unknown_path..'/personal.txt')=='preserved unknown content' and not lfs.symlinkattributes(quarantine),'restore lost original directory')
    Recovery.cancel(plugin)
    -- A published generation with a leftover ownership receipt retires metadata
    -- only. Its actual cached HTML and image bytes must remain untouched.
    stage=assert(Stage.create(book.cache_dir,key,{preserve=true}))
    local bitmap='published synthetic bitmap';write(stage.directory..'/images/img-0001.png',bitmap)
    local html=Content.render_mp_article_html(article,'<p>完成的合成正文</p><img src="'..stage.generation..'/images/img-0001.png"/>',key)
    assert(stage.output:write(html) and stage.output:sync())
    receipt=stage.lease.path
    stage.release_lease=function(self)
        if self.lease then assert(ffi.C.close(self.lease.fd)==0);self.lease.fd=nil;self.lease=nil end
    end
    local published=assert(stage:commit({ok=true,bytes=#html,images=1,image_bytes=#bitmap}))
    assert(lfs.attributes(receipt,'mode')=='file' and Versions.resolve(book.cache_dir,key)==published,'published receipt fixture failed')
    inspect();assert(row('Completed; record remains'));row('Completed; record remains').callback();plugin._mp_recovery_confirmation.ok_callback();finish()
    assert(not lfs.symlinkattributes(receipt) and read(published)==html and read(stage.directory..'/images/img-0001.png')==bitmap,'published generation cleanup removed content')
    Recovery.cancel(plugin)
    -- Changing an already saved body during confirmation invalidates the plan.
    stage=assert(Stage.create(book.cache_dir,key,{preserve=true}));pending=stage.directory;receipt=stage.lease.path;drop_creator(stage)
    inspect();row('Interrupted download').callback();dialog=plugin._mp_recovery_confirmation
    write(published..'.replacement',html..'<!-- preserved replacement -->');assert(os.rename(published..'.replacement',published))
    dialog.ok_callback();pump(function() return not plugin.mp_recovery_job end)
    assert(lfs.attributes(pending,'mode')=='directory' and lfs.attributes(receipt,'mode')=='file','stale confirmation removed residue')
    local top=UIManager:getTopmostVisibleWidget();if top~=plugin.ui and top.text then UIManager:close(top) end
    inspect();row('Interrupted download').callback();dialog=plugin._mp_recovery_confirmation;plugin:onSuspend();dialog.ok_callback()
    assert(not plugin.mp_recovery_job and lfs.attributes(pending,'mode')=='directory','suspended confirmation restarted repair')
    plugin:onResume();dialog.ok_callback()
    assert(not plugin.source_position.pauses.suspend and not plugin.mp_recovery_job and lfs.attributes(pending,'mode')=='directory','resume revived stale repair confirmation')
    Model.scan=old_scan;plugin:closeWeReadUI()
    assert(read(base)==saved and read(sidecar)==metadata and settings:get('books',{})[book.book_id].progress==.35
        and settings:get('books',{})[book.book_id].pending_upload_position.offset==19,'recovery changed notes or pending reading state')
    assert(UIManager:getTopmostVisibleWidget()==plugin.ui and not Cleanup.locked(book.cache_dir,key),'recovery left an overlay or mutation lock')
    assert(count('/web/mp/content')+count('/web/mp/articles')+count('/api/agent/gateway')==http
        and count('/web/book/read')==writes and count('/web/login/renewal')==renewals,'repair made account API calls')
    write(home..'/../evidence/mp-recovery.json',client:json_encode({result='PASS',synthetic_only=true,actual_background_scan=true,
        ui_heartbeat=true,inherited_writer_after_creator_fd_close=true,actual_writer_reaped=true,active_blocks_clean_and_quarantine=true,
        durable_ownership_record=true,inactive_owned_cleanup=true,confirmation_cancel_no_delete=true,saved_body_notes_preserved=true,
        unknown_quarantine_reversible=true,quarantine_images_protected=true,published_content_preserved=true,
        completed_receipt_only_cleanup=true,stale_confirmation_no_delete=true,suspend_cancels_repair=true,
        progress_pending_preserved=true,returns_to_reader=true,account_reads=0,account_data_writes=0,credential_renewals=0}))
    print('PASS: download recovery -> inherited writer lease, native active protection, reaped owner cleanup, reversible quarantine, published receipt retirement and stale/suspend guards')
end
