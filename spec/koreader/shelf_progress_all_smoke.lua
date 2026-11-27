-- Real native dialog, worker, local HTTP and SQLite; synthetic books only.
return function(plugin,books,count,control,wait_progress,evidence,imported)
    local UI=require('ui/uimanager');local Screen=require('device').screen;local socket=require('socket')
    local settings=plugin.settings
    local old_key,old_cookies=settings:get('api_key'),settings:get('cookies')
    local old_filters=plugin.shelf_filters
    local old_shelf=plugin.client:json_encode(settings:get('shelf'))
    local transient=plugin.showTransientInfo;local notices={}
    plugin.showTransientInfo=function(_,text) notices[#notices+1]=text end
    plugin:closeWeReadUI()
    settings:update_auth({api_key='',cookies={wr_vid='900000',wr_skey='synthetic-bulk-progress'}},{replace_cookies=true})
    local shelf=settings:get('shelf');shelf.view_mode='cover';shelf.paginated=true;shelf.sort_order='progress_desc'
    settings:set('shelf',shelf);settings:flush()
    local sample={};for i=1,8 do sample[i]=books[i] end
    plugin:applyShelfSnapshot(sample,{});plugin.shelf_group_key=nil;plugin.shelf_multi_groups={};plugin.shelf_filters={}
    plugin:showShelfView('books');wait_progress()
    local function pump(predicate)
        local deadline=socket.gettime()+35
        while not predicate() do
            assert(socket.gettime()<deadline,'bulk progress UI deadline')
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    local function start()
        local view=assert(plugin.shelf_view);view.on_sort();local menu=assert(view._shelf_popup)
        UI:forceRePaint();Screen:shot(evidence..'/bulk-progress-menu.png')
        local button
        for _,row in ipairs(menu.buttons) do for _,candidate in ipairs(row) do
            if candidate.text==require('weread.lib.i18n').tr('Update all bookshelf progress') then button=candidate end
        end end
        assert(button,'bulk update menu item missing');button.callback()
        pump(function() return plugin.shelf_progress_all_context~=nil end)
        local job=assert(plugin.shelf_progress_all_context)
        assert(job.dialog and job.dialog.progress_max==8,'native progress dialog missing')
        UI:forceRePaint();Screen:shot(evidence..'/bulk-progress-active.png')
        return job
    end
    local function wait_done()
        pump(function() return not plugin.shelf_progress_all_context
            and (not plugin.shelf_progress_all_worker or not plugin.shelf_progress_all_worker:busy()) end)
    end
    local writes=count('/web/book/read');local before=count('/web/book/getProgress')
    local job=start();wait_done()
    assert(job.done==8 and count('/web/book/getProgress')-before==8 and #notices==1,
        'full progress update missed books or made extra reads')
    local ids={};for _,book in ipairs(sample) do ids[#ids+1]=book.bookId end
    local cached=plugin.library_db:getShelfProgress(ids)
    for _,id in ipairs(ids) do assert(cached[id] and cached[id].book_id==id and cached[id].source=='web') end
    local pending=settings:get('books',{})[sample[1].bookId]
    assert(pending.pending_upload_position.percent==83,'bulk update changed the pending reading position')
    notices={};before=count('/web/book/getProgress');job=start()
    pump(function() return job.done>=5 end)
    assert(job.done==5);job.dialog.buttons[1][1].callback();wait_done()
    assert(not plugin.shelf_progress_all_context and #notices==1 and count('/web/book/getProgress')-before==5,
        'cancel did not retain one completed batch or stopped too late')
    notices={};before=count('/web/book/getProgress')
    assert(plugin.library_db:putShelfProgress({{book_id=sample[1].bookId,percent=17,fetched_at=1,source='web'}}))
    control{match='/web/book/getProgress',times=0,delay=2}
    job=start();job.dialog.buttons[1][1].callback();wait_done()
    local retained=assert(plugin.library_db:getShelfProgress({sample[1].bookId})[sample[1].bookId])
    assert(job.done==0 and #notices==1 and count('/web/book/getProgress')-before<=1 and retained.percent==17,
        'cancelling an active request committed an incomplete batch or started more reads')
    notices={};before=count('/web/book/getProgress')
    assert(plugin.library_db:putShelfProgress({{book_id=sample[1].bookId,percent=9,fetched_at=1,source='web'}}))
    control{match='/web/book/getProgress',times=1,status=429,delay=0}
    job=start();wait_done()
    assert(job.done==0 and #notices==1 and count('/web/book/getProgress')-before==1
        and plugin.shelf_progress_retry_at>os.time(),
        'rate limit did not stop the remaining books')
    assert(count('/web/book/read')==writes,'bulk display update wrote reading progress')
    control{match='',times=0,delay=0}
    plugin.shelf_progress_retry_at=nil;plugin.shelf_progress_retry_revision=nil
    plugin:closeWeReadUI()
    settings:update_auth({api_key='',cookies={}},{replace_cookies=true})
    local Credentials=require('weread.lib.native_credentials')
    local store=Credentials:new(settings)
    local scope=assert(settings:get_auth_scope())
    local _,revision=store:read()
    assert(store:save({vid=scope.vid,accessToken='mock-native-access',refreshToken='mock-native-refresh',
        deviceId='eink334691225'..string.rep('1',19)},scope,revision,#sample))
    local native_path='/book/getProgress'
    local native_writes=count('/book/read')
    local web_before=count('/web/book/getProgress')
    local gateway_before=count('/api/agent/gateway','/book/getprogress')
    local function expire(rows)
        local snapshots={}
        for _,book in ipairs(rows) do snapshots[#snapshots+1]={book_id=book.bookId,percent=9,fetched_at=0} end
        assert(plugin.library_db:putShelfProgress(snapshots))
    end
    local original_request=plugin.client.request
    local parent=tonumber(require('ffi').C.getpid())
    function plugin.client:request(options)
        if options.url:find('https://i.weread.qq.com/book/getProgress?',1,true)==1 then
            assert(tonumber(require('ffi').C.getpid())~=parent,'native progress blocked the UI')
            assert(options.method=='GET' and options.skip_cookie and options.persist_response_cookies==false
                and options.headers.vid==scope.vid and options.headers.accessToken=='mock-native-access'
                and not options.headers.Cookie,'native progress used the wrong authorization')
        end
        return original_request(self,options)
    end
    expire({sample[1]});before=count(native_path)
    plugin:showHome();wait_progress()
    local home=plugin.library_db:getShelfProgress({sample[1].bookId})[sample[1].bookId]
    assert(count(native_path)>before and home.source=='native' and home.percent==37
        and plugin.shelf_view.books[1]._shelf_progress==83,'native-only home did not update or lost pending position')
    plugin:closeWeReadUI()
    expire(books);before=count(native_path)
    plugin:showBookshelf();wait_progress()
    local visible=plugin.shelf_view:getVisibleBooks()
    assert(count(native_path)-before==#visible,'native-only shelf queried outside its visible area')
    for _,book in ipairs(visible) do
        assert(plugin.library_db:getShelfProgress({book.bookId})[book.bookId].source=='native')
    end
    plugin:closeWeReadUI()
    expire({imported,sample[1]});before=count(native_path)
    plugin:showShelfView('books',nil,nil,{page=1,refresh_progress=true,
        prepared_shelf={books={imported,sample[1]},accounts={}}})
    wait_progress()
    local imported_progress=plugin.library_db:getShelfProgress({imported.bookId})[imported.bookId]
    assert(count(native_path)-before==2 and imported_progress.source=='native' and imported_progress.exact_percent==0
        and imported._shelf_progress==0,'native-only visible shelf did not render the imported book')
    local online=plugin.isNetworkOnline
    plugin.isNetworkOnline=function() return false end
    plugin.shelf_view.on_display_change('view_mode','list')
    assert(plugin.shelf_view:itemStatus(imported):find('0%%') and count(native_path)-before==2,
        'offline shelf lost native imported progress')
    plugin.isNetworkOnline=online
    plugin:closeWeReadUI()
    sample[#sample]=imported;ids[#ids]=imported.bookId
    plugin:applyShelfSnapshot(sample,{})
    plugin:showShelfView('books');wait_progress()
    notices={};before=count(native_path);job=start();wait_done()
    assert(job.done==#sample and count(native_path)-before==#sample and #notices==1,'native-only bulk refresh missed books')
    cached=plugin.library_db:getShelfProgress(ids)
    for _,id in ipairs(ids) do assert(cached[id] and cached[id].source=='native') end
    assert(cached[sample[1].bookId].exact_percent==37 and cached[sample[2].bookId].exact_percent==0
        and cached[imported.bookId].exact_percent==0,
        'native-only cache lost explicit percentages')
    control{progress_response='foreign'}
    notices={};before=count(native_path);job=start();wait_done()
    local retained_native=plugin.library_db:getShelfProgress(ids)
    assert(job.done==0 and count(native_path)-before==1 and #notices==1 and plugin.shelf_progress_retry_at>os.time(),
        'foreign native progress did not stop the batch')
    for _,id in ipairs(ids) do assert(retained_native[id].fetched_at==cached[id].fetched_at) end
    control{progress_response='plain'}
    plugin.shelf_progress_retry_at=nil;plugin.shelf_progress_retry_revision=nil
    assert(count('/web/book/getProgress')==web_before and count('/api/agent/gateway','/book/getprogress')==gateway_before
        and count('/web/book/read')==writes and count('/book/read')==native_writes,'native-only update contacted another route or wrote progress')
    plugin:closeWeReadUI()
    plugin.shelf_filters={}
    plugin.shelf_group_key=nil
    plugin.shelf_multi_groups={}
    local function refresh_and_wait()
        expire(books)
        plugin:refreshBookshelf(nil)
        pump(function() return not plugin.shelf_refreshing and plugin.shelf_view~=nil end);wait_progress()
        return plugin.shelf_view:getVisibleBooks()
    end
    local baseline=count(native_path)
    local before_summary=refresh_and_wait()
    baseline=count(native_path)-baseline
    assert(baseline==#before_summary,'baseline did not query each visible book')
    plugin:closeWeReadUI()
    control{shelf_progress=true}
    local summary_gets,shelf_gets=count(native_path),count('/shelf/sync')
    local summary_visible=refresh_and_wait()
    local missing=sample[2].bookId
    local visible_missing=false
    for _,book in ipairs(summary_visible) do if book.bookId==missing then visible_missing=true end end
    assert(visible_missing and #summary_visible==baseline and baseline>1 and count(native_path)-summary_gets==1
        and count('/shelf/sync')-shelf_gets==1,'shelf refresh did not reuse its summary or fetch the missing visible book')
    local summary_all=plugin.library_db:getShelfProgress({sample[1].bookId,missing,books[#books].bookId})
    assert(summary_all[sample[1].bookId].updated_at==1700000000 and summary_all[missing].updated_at==nil
        and summary_all[books[#books].bookId].updated_at==1700000000,'shelf summary was not persisted for nonvisible books')
    plugin:closeWeReadUI();plugin:showHome();wait_progress();expire(books)
    summary_gets,shelf_gets=count(native_path),count('/shelf/sync')
    plugin:refreshHome()
    pump(function() return not plugin.shelf_refreshing end);wait_progress()
    local home_missing=0
    for _,book in ipairs(plugin.shelf_view:getVisibleBooks()) do if book.bookId==missing then home_missing=1 end end
    assert(count('/shelf/sync')-shelf_gets==1 and count(native_path)-summary_gets==home_missing
        and plugin.shelf_view.books[1]._shelf_progress==83,'home refresh repeated a summary read or lost pending local progress')
    assert(count('/book/read')==native_writes and count('/web/book/read')==writes,'shelf summary updated reading state')
    print(('PASS: native shelf summary reused (%d -> 1 progress GETs); home refresh reused summary'):format(baseline))
    control{shelf_progress=false}
    plugin.client.request=original_request
    local _,updated_revision=store:read()
    assert(store:clear(scope,updated_revision))
    plugin:closeWeReadUI();plugin.showTransientInfo=transient;plugin.shelf_filters=old_filters
    settings:update_auth({api_key=old_key,cookies=old_cookies},{replace_cookies=true})
    settings:set('shelf',plugin.client:json_decode(old_shelf));settings:flush()
    plugin:applyShelfSnapshot(plugin.library_db:getShelf(),plugin.library_db:getShelfArchives())
    print('PASS: native-only home and shelf progress, imported book offline and in bulk update; cancel and 429; no reading writes')
end
