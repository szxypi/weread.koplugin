-- Real native dialog, worker, local HTTP and SQLite; synthetic books only.
return function(plugin,books,count,control,wait_progress,evidence)
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
    plugin:closeWeReadUI();plugin.showTransientInfo=transient;plugin.shelf_filters=old_filters
    settings:update_auth({api_key=old_key,cookies=old_cookies},{replace_cookies=true})
    settings:set('shelf',plugin.client:json_decode(old_shelf));settings:flush()
    plugin:applyShelfSnapshot(plugin.library_db:getShelf(),plugin.library_db:getShelfArchives())
    print('PASS: bulk progress native menu, batched HTTP/SQLite, cancel and 429; no reading writes')
end
