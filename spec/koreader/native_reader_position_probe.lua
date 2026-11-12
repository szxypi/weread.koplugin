-- Packaged plugin -> native ReaderUI -> manual and timer -> real workers/SQLite.
-- Only the dedicated loopback synthetic fixture may receive requests.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
assert(home:match('^/dev/shm/weread%-native%-reader%-[%w_]+/profile$'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'});G_reader_settings:saveSetting('language','zh_CN')
require('gettext').changeLang('zh_CN')
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local json,socket,ffi=require('json'),require('socket'),require('ffi');require('ffi/posix_h')
local report={result='UNVERIFIED',phase='init',failed_line=0,native_posts=0,web_posts=0,manual=false,timed=false,
    unknown_not_replayed=false,pending_reopened=false,original_local_units=false,summary_not_in_checkpoints=false,
    parent_only_document=true,workers_reaped=false,reader_from_shelf=false,timer_cancelled=false,source_workers=false}
Device.screen.shot=function() error('native_reader/screenshots_disabled',0) end
local plugin,reader,memory,counters;local pids={};local parent=tonumber(ffi.C.getpid())
local function pump(predicate)
    local deadline=socket.gettime()+50
    while not predicate() do
        assert(socket.gettime()<deadline,'native_reader/deadline')
        if plugin then
            for _i,worker in pairs({plugin.source_position.worker,plugin.source_position.preview_worker,
                plugin.source_upload.native and plugin.source_upload.native.worker,
                plugin.source_upload.native and plugin.source_upload.native.service.worker}) do
                if worker.job then pids[worker.job.pid]=true end
            end
        end
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local function clean(base)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=base do UI:close(UI:getTopmostVisibleWidget()) end
end
local ok,reason=pcall(function()
    local port=assert(tonumber(os.getenv('WEREAD_NATIVE_READER_PORT')))
    assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=port})
    local Settings=require('weread.lib.settings');local settings=Settings:new()
    assert(settings.mock_endpoint=='http://127.0.0.1:'..port)
    local reopen=arg[1]=='reopen' or arg[1]=='review-reopen'
    if not reopen then
        local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0
        settings:set('sync',sync)
        local cache=settings:get('cache');cache.download_book_images=false;cache.download_underlines_and_thoughts=false
        cache.auto_prefetch_next_chapter=false;settings:set('cache',cache)
        local config=settings:get('read_report');config.enabled=false;settings:set('read_report',config);settings:flush()
        local grant={vid='900000',accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh',
            deviceId='eink334691225'..string.rep('1',19)}
        assert(require('weread.lib.native_credentials'):new(settings):save(grant,settings:get_auth_scope(),0,26))
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
    FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function() return not reopen end;plugin.isNetworkConnected=plugin.isNetworkOnline
    plugin:showHome()
    if not reopen then plugin.shelf_view.on_refresh();pump(function() return #(plugin.library_db:getShelf() or {})>0 and not plugin.busy_message end) end
    plugin:closeWeReadUI();plugin:showBookshelf()
    local selected,index
    for position,book in ipairs(plugin.shelf_view.books) do if tostring(book.bookId or book.book_id)=='900001' then index=position;break end end
    assert(index);local view=plugin.shelf_view;local page=math.floor((index-1)/view.page_size)+1
    if page~=view.page then plugin:showShelfView('books',nil,nil,{page=page});view=plugin.shelf_view end
    for _i,book in ipairs(view:getVisibleBooks()) do if tostring(book.bookId or book.book_id)=='900001' then selected=book;break end end
    assert(selected);plugin.shelf_view.on_select(selected)
    pump(function() return Reader.instance or plugin._book_detail_view and not plugin.book_metadata_context end)
    if not Reader.instance then
        local clicked=false
        for _i,buttons in ipairs({plugin._book_detail_view._action_buttons or {},plugin._book_detail_view._footer_actions or {}}) do
            for _j,button in ipairs(buttons) do if button.text==require('weread.lib.plugin_util').tr('▤ Read') then button.callback();clicked=true;break end end
            if clicked then break end
        end
        assert(clicked)
    end
    pump(function() return Reader.instance and Reader.instance.weread end)
    reader=Reader.instance;plugin=reader.weread
    plugin.isNetworkOnline=function() return not reopen end;plugin.isNetworkConnected=plugin.isNetworkOnline
    pump(function() return plugin.source_position:current() and plugin.progress_sync.current_book_id end)
    report.reader_from_shelf=reader.document.file:match('%.epub$')~=nil
    local sync=plugin.progress_sync;local id=assert(plugin:detectWeReadBook())
    if reopen then
        if arg[1]=='review-reopen' then
            local kind=assert(os.getenv('WEREAD_NATIVE_REVIEW_CASE'))
            local archived=kind=='local' or kind=='cloud'
            local pending=plugin.source_upload:_native().service:pending()
            local db=assert(plugin.library_db:open());local count=tonumber(db:rowexec('SELECT COUNT(*) FROM native_position_write_history'))
            local raw=archived and db:rowexec('SELECT payload FROM native_position_write_history');db:close()
            local history=raw and json.decode(raw)
            assert(count==(archived and 1 or 0) and (archived and not pending or not archived and pending and pending.phase=='pending'))
            assert(not archived or history.phase=='pending','offline recovery history claimed ACK')
            assert((plugin.settings:get_book(id).pending_upload_position~=nil)==not archived)
            report.review_reopen={kind=kind,journal_idle=archived,unknown_history=archived,pending_preserved=not archived,
                local_intent=not archived,history_rows=count}
            report.phase,report.result='complete','PASS';clean(reader);reader:onClose(false);return
        end
        local pending=assert(plugin.source_upload:_native().service:pending())
        assert(pending.phase=='pending' and plugin.settings:get_book(id).pending_upload_position and not sync.verified)
        report.pending_reopened=true;report.phase,report.result='complete','PASS';clean(reader);reader:onClose(false);return
    end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local request=plugin.client.request
    function plugin.client:request(options)
        assert(self.settings.mock_endpoint=='http://127.0.0.1:'..port)
        if options.url=='https://weread.qq.com/web/book/read' then counters[1]=counters[1]+1;error('native_reader/web_write_forbidden',0) end
        if options.url=='https://i.weread.qq.com/book/read' then
            assert(tonumber(ffi.C.getpid())~=parent,'native_reader/synchronous_write')
            local row=assert(plugin.source_upload.native.service.journal:read())
            local body=json.decode(options.body)
            assert(row.phase=='pending' and body.chapterOffset==row.metadata.desired.chapter_offset
                and body.summary==row.metadata.desired.summary and body.readingTime==0 and body.bookVersion==0
                and next(body.hours)==nil and not plugin.source_dispatch:pending(id))
            counters[0]=counters[0]+1
        end
        return request(self,options)
    end
    for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar'}) do
        local original=reader.document[name]
        reader.document[name]=function(document,...)
            assert(tonumber(ffi.C.getpid())==parent,'native_reader/inherited_document');return original(document,...)
        end
    end
    local function move()
        clean(reader);reader.rolling:onGotoPage(reader:getCurrentPage()==2 and 1 or 2)
        pump(function() return plugin.source_position:current()~=nil end)
        assert(plugin.source_position:current().basis=='raw_txt_utf16')
    end
    report.phase='manual';move();local local_before=assert(sync:capture_local())
    assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
    local choice=assert(UI:getTopmostVisibleWidget());assert(choice.cancel_text==require('weread.lib.plugin_util').tr('Keep KOReader progress'))
    choice.cancel_callback();UI:close(choice);pump(function() return not sync.uploading end)
    local saved=plugin.settings:get_book(id);local uploaded=assert(saved.last_uploaded_position)
    assert(counters[0]==1 and not saved.pending_upload_position and sync.verified and uploaded.wire_basis=='raw_txt_utf16')
    assert(saved.last_local_position.chapter_offset==local_before.chapter_offset and uploaded.source_position.chapter_offset==local_before.source_position.chapter_offset)
    assert(not uploaded.summary and not saved.last_local_position.summary and not saved.last_remote_position.summary)
    report.manual,report.original_local_units,report.summary_not_in_checkpoints=true,true,true
    if arg[1]=='recovery' then
        report.recovery_case={kind=assert(os.getenv('WEREAD_NATIVE_RECOVERY_CASE')),confirmed=false,fresh_source=false,closed=false,
            cancelled=false,save_only=false,unknown_not_replayed=false,local_kept=false,grant_revision=0,renewal_pending=false,
            source_passes=0,auth_posts=0,expired_responses=0,no_closed_document_calls=false,workers_reaped=false,timer_triggered=false,failed_line=0}
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'native_reader_recovery_case.lua')(
            reader,plugin,pump,clean,counters,pids,report.recovery_case)
        report.source_workers,report.workers_reaped=true,true
        report.phase,report.result='complete','PASS';return
    end
    if arg[1]=='review' then
        report.review_case={kind=assert(os.getenv('WEREAD_NATIVE_REVIEW_CASE')),unknown_retained=false,review_worker=false,
            cancelled=false,storage_preserved=false,archived_unknown=false,newer_local_kept=false,fresh_choice=false,
            new_request=false,cloud_choice=false,workers_reaped=false,failed_line=0}
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'native_reader_review_case.lua')(
            reader,plugin,pump,clean,counters,pids,report.review_case)
        report.source_workers,report.workers_reaped=true,true
        report.phase,report.result='complete','PASS';return
    end
    if arg[1]=='close' then
        report.close_case={kind=assert(os.getenv('WEREAD_NATIVE_CLOSE_CASE')),document_closed=false,archive_worker=false,
            workers_reaped=false,no_closed_document_calls=false,confirmed=false,unknown_retained=false,cancelled=false,
            close_posts=0,failed_line=0}
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'native_reader_close_case.lua')(
            reader,plugin,pump,clean,counters,pids,report.close_case)
        report.source_workers,report.workers_reaped=true,true
        report.phase,report.result='complete','PASS';return
    end
    local timer=sync.interval;local clock=100;timer.now=function() return clock end
    local config=plugin.settings:get('sync');config.upload_interval_minutes=1;plugin.settings:set('sync',config)
    local function due()
        clock=assert(timer.due);local task=assert(timer.task);UI:unschedule(task);task()
    end
    report.phase='timer';move();assert(timer.task,'native_reader/txt_timer_not_armed');due()
    pump(function() return not timer.cycle and not sync.uploading end)
    assert(counters[0]==2 and not sync.dirty and sync.verified and not plugin.source_upload.native.service:pending())
    report.timed=true
    report.phase='cancel';move();due()
    pump(function() return sync.uploading and plugin.source_position.preview_worker and plugin.source_position.preview_worker.job end)
    local pid=plugin.source_position.preview_worker.job.pid;pids[pid]=true
    config.upload_interval_minutes=0;plugin.settings:set('sync',config);timer:reschedule()
    pump(function() return require('ffi/util').isSubProcessDone(pid) end)
    assert(not sync.uploading and counters[0]==2 and plugin.settings:get_book(id).pending_upload_position)
    report.timer_cancelled=true
    local _,code=plugin.client:request{url='https://weread.qq.com/mock/native-control',method='POST',body=json.encode{mode='noack'},
        headers={['Content-Type']='application/json'},skip_cookie=true,persist_response_cookies=false,sensitive=true};assert(code==200)
    report.phase='unknown';config.upload_interval_minutes=1;plugin.settings:set('sync',config);timer:reschedule();due()
    pump(function() return not sync.uploading and not timer.cycle end)
    assert(counters[0]==3 and not sync.verified and plugin.source_upload.native.service:pending().phase=='pending')
    clock=clock+600;for _i=1,4 do UI:setInputTimeout(0);UI:handleInput() end
    assert(counters[0]==3 and not timer.task and plugin.settings:get_book(id).pending_upload_position)
    report.unknown_not_replayed=true
    config.upload_interval_minutes=0;plugin.settings:set('sync',config);plugin.settings:flush();timer:reschedule()
    clean(reader);reader:onClose(false)
    for child_pid in pairs(pids) do pump(function() return require('ffi/util').isSubProcessDone(child_pid) end) end
    report.source_workers,report.workers_reaped=next(pids)~=nil,next(pids)~=nil
    report.phase,report.result='complete','PASS'
end)
if plugin and plugin.source_upload then pcall(plugin.source_upload.cancel,plugin.source_upload) end
if counters then report.native_posts,report.web_posts=tonumber(counters[0]),tonumber(counters[1]);ffi.C.munmap(memory,4096) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('native_reader_position_probe%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_NATIVE_READER_RESULT='..json.encode(report)..'\n');io.stdout:flush()
os.exit(ok and 0 or 1)
