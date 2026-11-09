-- Real fork, HTTP, exclusive staging, cancellation and generation-scoped images.
return function(plugin,count,flush,home,pump)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local lfs=require('libs/libkoreader-lfs')
    local socket=require('socket')
    local ffi=require('ffi')
    local Model=require('weread.lib.mp_download')
    local Stage=require('weread.lib.mp_download_stage')
    local Identity=require('weread.lib.mp_cache_identity')
    local Output=require('weread.lib.notes_export_file')
    local parent=tonumber(ffi.C.getpid())
    local settings,client=plugin.settings,plugin.client
    local original_cache=settings:get('cache',{})
    local cache={};for k,v in pairs(original_cache) do cache[k]=v end
    cache.download_mp_images=true;settings:set('cache',cache);settings:flush()
    local book={book_id='MP_WXS_900097',title='合成后台公众号',cache_dir=settings.data_dir..'/mp-background',
        progress=.2,pending_upload_position={offset=7}}
    local article={reviewId='background-fixture',title='后台文章'}
    book.mp_articles={article}
    local books=settings:get('books',{});books[book.book_id]=book;settings:set('books',books);settings:flush()
    local before=client:json_encode(settings:get('books',{})[book.book_id])
    local writes=count('/web/book/read');local renewals=count('/web/login/renewal')
    local old_open,old_write,old_request=plugin.openFile,Model.write,client.request
    local opened
    plugin.openFile=function(_self,path) opened=path end
    Model.write=function(...)
        assert(tonumber(ffi.C.getpid())~=parent,'article download blocked UI process')
        socket.sleep(.4);return old_write(...)
    end
    client.request=function(self,opts)
        assert(tonumber(ffi.C.getpid())~=parent and opts.method=='GET','article HTTP blocked UI or wrote cloud state')
        assert(opts.skip_cookie and opts.persist_response_cookies==false,'child HTTP could mutate settings')
        if opts.diagnostic_api=='mp_image' then
            assert(not opts.headers.Cookie and not opts.headers.Authorization and not opts.headers['x-wr-ticket'] and not opts.headers['x-wrpa-0'],'image request carried owner credentials')
        end
        return old_request(self,opts)
    end
    local function read(path) local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close();return raw end
    local function write(path,raw) local file=assert(io.open(path,'wb'));file:write(raw);file:close() end
    local function close_info()
        local top=UIManager:getTopmostVisibleWidget();if top~=plugin.ui and top.text then UIManager:close(top) end
    end
    local function start()
        opened=nil;assert(plugin:downloadMPArticleAndRead(book,article));return assert(plugin.mp_download_job)
    end
    local heartbeat=false
    local first=start();UIManager:scheduleIn(.1,function()
        heartbeat=plugin.mp_download_job==first
        UIManager:forceRePaint();Screen:shot(home..'/../evidence/mp-background-cancel.png')
    end)
    pump(function() return not plugin.mp_download_job end)
    assert(opened and heartbeat and not plugin.busy_message,'background article did not finish or UI heartbeat stopped')
    local path=opened;local previous=read(path)
    local relative=assert(previous:match('src="([^"<>]+/images/img%-0001%.png)"'))
    local root=path:match('^(.*)/[^/]+$');local old_bitmap=read(root..'/'..relative)
    assert(#old_bitmap>32 and previous:find('合成后台文章正文',1,true),'bitmap/body not published together')
    assert(not lfs.symlinkattributes(first.stage.directory..'/body.html'),'unexpected stage body')
    local doc=assert(require('document/documentregistry'):openDocument(path));assert(doc:loadDocument());doc:render()
    assert((doc:getTextFromXPointer('/html/body') or doc:getTextFromXPointer('/body')):find('合成后台文章正文',1,true),'CRE lost background body');doc:close()
    -- Generated image resources must also survive standalone EPUB export.
    local target=assert(Output.create(settings.data_dir..'/mp-background-export','Background','epub'))
    local export=require('weread.lib.mp_export').write({path=path,identity=lfs.symlinkattributes(path),book=book,article=article},target,{})
    assert(export.ok and export.images==1 and export.missing==0 and target:accept(export.bytes),'generation images not exported or duplicated')
    local members=require('weread.lib.source_archive').read(target.path,{['EPUB/images/image-1.png']=1024*1024})
    assert(members and members['EPUB/images/image-1.png']==old_bitmap,'EPUB image differs from downloaded generation')
    -- Cancel during the child delay; deletion must wait for termination/reaping.
    local cancel=start();local pending=cancel.stage.directory
    UIManager:scheduleIn(.1,function() plugin:cancelMPArticleDownload() end)
    pump(function() return not plugin.mp_download_job and not lfs.symlinkattributes(pending) end)
    assert(not opened and read(path)==previous and read(root..'/'..relative)==old_bitmap,'cancel changed previous body or image')
    -- Closing, suspending and changing ownership must invalidate results.
    for _,change in ipairs({'close','suspend','session','epoch','ticket','cache'}) do
        local job=start();local directory=job.stage.directory
        local ticket=settings:get('wr_ticket','');local cache_root=settings.cache_dir
        UIManager:scheduleIn(.1,function()
            if change=='close' then plugin:closeWeReadUI()
            elseif change=='suspend' then plugin:onSuspend()
            elseif change=='session' then plugin._reader_session_gen=(plugin._reader_session_gen or 0)+1
            elseif change=='epoch' then plugin.discovery_epoch=(plugin.discovery_epoch or 0)+1
            elseif change=='ticket' then settings:set('wr_ticket','synthetic-replaced')
            else settings.cache_dir=cache_root..'-changed' end
        end)
        pump(function() return not plugin.mp_download_job and not lfs.symlinkattributes(directory) end)
        settings:set('wr_ticket',ticket);settings.cache_dir=cache_root
        assert(not opened and read(path)==previous and read(root..'/'..relative)==old_bitmap,'stale/cancelled job replaced cache: '..change)
    end
    -- Fail after the generation directory moves but before HTML is published.
    local rename=os.rename
    rawset(os,'rename',function(from,to) if to==path then return nil,'injected' end;return rename(from,to) end)
    local failed=start();pump(function() return not plugin.mp_download_job end);rawset(os,'rename',rename)
    assert(not opened and read(path)==previous and read(root..'/'..relative)==old_bitmap and not lfs.symlinkattributes(failed.stage.directory),'failed final rename changed old cache or left generation')
    close_info()
    -- A replaced active file is never overwritten by a job captured earlier.
    local concurrent=start();local temp=path..'.replacement';write(temp,previous..'<!-- replacement -->');assert(os.rename(temp,path))
    local replacement=read(path);pump(function() return not plugin.mp_download_job end)
    assert(not opened and read(path)==replacement and not lfs.symlinkattributes(concurrent.stage.directory),'concurrent active replacement overwritten')
    close_info()
    -- A replaced stage body survives cleanup; no symlinks are followed.
    local stage=assert(Stage.create(book.cache_dir,Identity.key(book,article)))
    local staged_path=stage.output.path;write(staged_path..'.replacement','keep replacement');assert(os.rename(staged_path..'.replacement',staged_path))
    stage:cleanup();assert(read(staged_path)=='keep replacement','cleanup deleted a replacement body')
    os.remove(staged_path);lfs.rmdir(stage.directory)
    stage=assert(Stage.create(book.cache_dir,Identity.key(book,article)))
    local outside=settings.data_dir..'/mp-stage-outside';assert(lfs.mkdir(outside));write(outside..'/keep','keep')
    assert(lfs.rmdir(stage.directory..'/images'));assert(lfs.link(outside,stage.directory..'/images',true))
    assert(not stage:commit({ok=true,bytes=1,images=0,image_bytes=0}),'stage image-directory symlink accepted')
    stage:cleanup();assert(read(outside..'/keep')=='keep','stage cleanup followed image directory symlink')
    os.remove(stage.directory..'/images');lfs.rmdir(stage.directory)
    -- Invalid receipts and a moved/replaced stage directory cannot publish.
    for _,receipt in ipairs({{ok=true,bytes=1,images=0,image_bytes=0},
        {ok=true,bytes=1,images=257,image_bytes=0},{ok=true,bytes=1,images=0,image_bytes=-1}}) do
        stage=assert(Stage.create(book.cache_dir,Identity.key(book,article)))
        assert(stage.output:write('wrong marker'))
        assert(not stage:commit(receipt),'invalid stage receipt accepted')
        stage:cleanup();assert(read(path)==replacement,'invalid receipt changed active HTML')
    end
    stage=assert(Stage.create(book.cache_dir,Identity.key(book,article)))
    local original=stage.directory;assert(os.rename(original,original..'.moved'));assert(lfs.mkdir(original))
    write(original..'/keep','replacement directory');stage:cleanup()
    assert(read(original..'/keep')=='replacement directory' and lfs.attributes(original..'.moved','mode')=='directory','cleanup removed replaced stage root')
    os.remove(original..'/keep');assert(lfs.rmdir(original));assert(os.rename(original..'.moved',original));stage:cleanup()
    -- A successful second attempt keeps the earlier immutable bitmap generation.
    start();pump(function() return not plugin.mp_download_job end)
    assert(opened==path and read(path)~=previous and read(root..'/'..relative)==old_bitmap,'successful refresh reused old image generation')
    -- A failed metadata save reports the completed cache without crashing UI.
    local setter=settings.set
    settings.set=function(self,key,value) if key=='books' then error('synthetic metadata failure') end;return setter(self,key,value) end
    local metadata=start();pump(function() return not plugin.mp_download_job end);settings.set=setter
    assert(not opened and not plugin.busy_message and Identity.valid(book.cache_dir,Identity.key(book,article))
        and lfs.attributes(metadata.stage.directory,'mode')=='directory','metadata error lost completed cache or blocked UI')
    close_info()
    assert(client:json_encode(settings:get('books',{})[book.book_id])==before,'background completion replaced progress/pending intent')
    Model.write=old_write;client.request=old_request;plugin.openFile=old_open;plugin:closeWeReadUI()
    settings:set('cache',original_cache);settings:flush()
    assert(count('/web/book/read')==writes and count('/web/login/renewal')==renewals,'background article wrote reading data or renewed credentials')
    local report={result='PASS',synthetic_only=true,ui_heartbeat=true,http_in_child=true,anonymous_cdn=true,
        images_streamed_and_deduplicated=true,cre_rendered_body=true,generation_images_in_epub=true,
        cancel_preserves_old_body_and_images=true,close_suspend_session_epoch_auth_config_guard=true,
        failed_publish_preserves_old_generation=true,concurrent_file_replacement_preserved=true,
        replacement_stage_body_preserved=true,replaced_stage_root_preserved=true,invalid_receipts_rejected=true,symlink_cleanup_does_not_follow=true,
        successful_refresh_retains_prior_images=true,metadata_failure_keeps_complete_cache=true,local_progress_intent_preserved=true,account_data_writes=0,credential_renewals=0}
    write(home..'/../evidence/mp-background.json',client:json_encode(report))
    print('PASS: MP background download -> responsive UI, real child HTTP/CDN, staged body/bitmaps, CRE/EPUB, cancellation/ownership/failed publish and replacement-safe cleanup')
end
