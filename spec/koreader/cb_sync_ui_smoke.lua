-- Full imported-book manual sync through the normal plugin and mock server.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local Settings=require('weread.lib.settings');local Client=require('weread.lib.client');local Content=require('weread.lib.content')
local settings=Settings:new();assert(settings.mock_endpoint)
local id='CB_SyntheticResume'
if os.getenv('WEREAD_TEST_CB_SYNC_REOPEN')=='1' then
    local requests=0;Client.request=function() requests=requests+1;error('unexpected offline request') end
    local socket=require('socket');local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
    local host=assert(FM.instance.weread);host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
    assert(host:startBookReading(assert(settings:get_book(id))))
    local Reader=require('apps/reader/readerui');local deadline=socket.gettime()+45
    while not (Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id) do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'offline CB sync reopen timed out')
    end
    local plugin=Reader.instance.weread
    plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local saved=assert(plugin.settings:get_book(id))
    assert(plugin.source_dispatch:pending(id) and saved.pending_upload_position
        and saved.pending_upload_reason=='upload_readback_unconfirmed','fresh process lost uncertain position')
    plugin.progress_sync:on_resume();UI:setInputTimeout(0);UI:handleInput()
    assert(not plugin.progress_sync.verified and requests==0,'offline restart retried an uncertain upload')
    print('\nWEREAD_CB_SYNC_REOPEN='..Client:new(settings):json_encode({result='PASS',fresh_process=true,
        journal_preserved=true,pending_preserved=true,automatic_disabled=true,requests=requests}))
    os.exit(0)
end
settings:update_auth({account={user_vid='900000',name='Synthetic'},cookies={wr_vid='900000',wr_skey='synthetic-cloud-session'}},{replace_cookies=true})
local client=Client:new(settings)
local book={book_id=id,bookId=id,title='合成导入书',author='合成作者'}
Content.ensure_reader_state(client,book);local chapters=Content.fetch_catalog(client,book)
assert(Content.save_catalog_cache(client,settings,book,chapters))
local single=os.getenv('WEREAD_TEST_CB_CLOUD_SINGLE')=='1'
local noack=os.getenv('WEREAD_TEST_CB_SYNC_NOACK')=='1'
local cloud=os.getenv('WEREAD_TEST_CB_SYNC_CLOUD')=='1'
local timed=os.getenv('WEREAD_TEST_CB_SYNC_TIMER')=='1'
local timer_unknown=os.getenv('WEREAD_TEST_CB_TIMER_UNKNOWN')=='1'
local close_outcome=os.getenv('WEREAD_TEST_CB_SYNC_CLOSE') or ''
local time_outcome=os.getenv('WEREAD_TEST_CB_SYNC_TIME') or ''
local file
if single then
    file=Content.fetch_chapter_epub(client,settings,book,chapters[1]);book.cached_file=file;book.cached_chapters={['1']=file}
else
    file=Content.fetch_chapters_epub(client,settings,book,chapters,{suffix='cb-manual-sync'});book.cached_file=file;book.cached_full_book=file
end
book.chapters=chapters;settings:set('books',{[id]=book})
settings:set('sync',{pull_on_open=false,upload_on_close=false,ask_on_conflict=true,upload_interval_minutes=timed and 1 or 0})
settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
local socket=require('socket')
local function wait(predicate)
    local deadline=socket.gettime()+45
    while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'imported manual sync timed out') end
end
local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
local host=assert(FM.instance.weread);assert(host:startBookReading(book))
local Reader=require('apps/reader/readerui')
wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id end)
local reader=Reader.instance;local plugin=reader.weread
plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
reader.rolling:onGotoPage(2)
wait(function() local point=plugin.source_position:current();return point and point.chapter_uid=='1' end)
local original=assert(plugin.source_position:current())
local sync=plugin.progress_sync;local choice,box,notice
local show=UI.show
function UI:show(widget,...)
    if choice and widget.cancel_callback==choice.keep_local then box=widget end
    return show(self,widget,...)
end
local old_choice=sync.on_choice
sync.on_choice=function(value) choice=value;old_choice(value) end
sync.notify=function(code,data) notice={code=code,data=data} end
local http,ltn12=require('socket.http'),require('ltn12')
local function control(value)
    local text=client:json_encode(value);local output={}
    local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
        headers={['Content-Type']='application/json',['Content-Length']=tostring(#text)},source=ltn12.source.string(text),sink=ltn12.sink.table(output)}
    assert(code==200)
end
local function select_local()
    choice,box,notice=nil,nil,nil
    assert(sync:sync_now());wait(function() return choice and box end)
    UI:close(box);choice.keep_local()
end
choice,box,notice=nil,nil,nil
if cloud then
    local local_point=assert(sync:capture_local());local account=assert(plugin.library_db:accountKey())
    assert(plugin.settings:patch_reading_state(id,{pending_upload_position=local_point,pending_upload_reason='synthetic_pending',
        pending_upload_account=account}))
end
assert(sync:sync_now());wait(function() return choice and box end)
if cloud then
    UI:close(box);choice.use_remote()
    if single then
        wait(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
        plugin.cloud_source_request.confirm.ok_callback()
    end
    local target=assert(tonumber(os.getenv('WEREAD_TEST_CB_CLOUD_TARGET')))
    wait(function()
        if Reader.instance and Reader.instance.weread then reader=Reader.instance;plugin=reader.weread end
        local point=plugin.source_position and plugin.source_position:current()
        return point and point.chapter_uid=='6' and point.chapter_offset==target
            and not plugin.cloud_source_request and not plugin.cloud_source_incoming
    end)
    local saved=assert(plugin.settings:get_book(id))
    assert(saved.pending_upload_position and saved.pending_upload_reason=='synthetic_pending','cloud choice lost local intent')
    assert(not plugin.progress_sync.verified and not plugin.progress_sync.interval.task,'cloud choice enabled automatic uploads')
    reader:onClose(false)
    print('\nWEREAD_CB_SYNC_CLOUD='..client:json_encode({result='PASS',choice=true,native_navigation=true,
        pending_preserved=true,automatic_disabled=true,single=single}))
    os.exit(0)
end
control({progress_offset_delta=1});UI:close(box);choice.keep_local()
wait(function() return notice~=nil end)
assert(notice.code=='upload_failed' and notice.data.error=='source_remote_changed','changed cloud did not stop upload')
assert(not sync.verified and not plugin.source_dispatch:pending(id),'failed source check enabled sending')
control({progress_offset_delta=0,progress_confirmation=noack and 'noack' or 'plain'})
select_local();wait(function() return notice~=nil end)
assert(notice.code==(noack and 'upload_unconfirmed' or 'upload_success'),
    'explicit local sync returned unexpected status: '..tostring(notice.data and notice.data.error))
local chunks={};local _,code=http.request{url=settings.mock_endpoint..'/__state',proxy=settings.mock_endpoint,sink=ltn12.sink.table(chunks)}
assert(code==200);local server=client:json_decode(table.concat(chunks));local remote=server.progress[id]
assert(tostring(remote.chapterUid)==original.chapter_uid and remote.chapterOffset==original.chapter_offset,'cloud did not receive native point')
assert(sync.verified==not noack and not sync.interval.task,'manual sync verification or disabled timer was incorrect')
local saved=assert(plugin.settings:get_book(id))
if noack then
    assert(plugin.source_dispatch:pending(id) and saved.pending_upload_position
        and saved.pending_upload_reason=='upload_readback_unconfirmed','unknown result lost its journal')
    sync:on_resume();UI:setInputTimeout(0);UI:handleInput()
else
    assert(not plugin.source_dispatch:pending(id) and not saved.pending_upload_position,'confirmed sync retained pending state')
end
if timed then
    local timer=sync.interval;local clock=100;timer.now=function() return clock end
    reader.rolling:onGotoPage(3)
    wait(function() local point=plugin.source_position:current();return point and point.chapter_offset~=original.chapter_offset and sync.dirty and timer.task end)
    local target=assert(plugin.source_position:current())
    clock=timer.due;UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
    wait(function() return not timer.cycle and not sync.uploading end)
    assert(sync.verified and not sync.dirty and not timer.task and not plugin.source_dispatch:pending(id),'timed imported position was not confirmed')
    local received={};local _,status=http.request{url=settings.mock_endpoint..'/__state',proxy=settings.mock_endpoint,sink=ltn12.sink.table(received)}
    assert(status==200);local current=client:json_decode(table.concat(received)).progress[id]
    assert(current.chapterOffset==target.chapter_offset,'timer sent a different source position')
    reader.rolling:onGotoPage(2)
    wait(function() local point=plugin.source_position:current();return point and point.chapter_offset~=target.chapter_offset and sync.dirty and timer.task end)
    control(timer_unknown and {progress_confirmation='noack'} or {progress_offset_delta=1});clock=timer.due
    UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
    if timer_unknown then
        wait(function() return not sync.uploading and not timer.cycle end)
        assert(not sync.verified and plugin.source_dispatch:pending(id) and not timer.task,'uncertain timer lost its journal')
        clock=clock+600
        for _i=1,4 do UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
        assert(plugin.source_dispatch:pending(id) and not sync.uploading and not timer.task,'uncertain timer retried')
    else
        wait(function() return sync.state=='awaiting_choice' end)
        assert(not sync.verified and not timer.task and not sync.uploading,'changed cloud did not stop imported timer')
        if box then UI:close(box) end
        control({progress_offset_delta=0})
    end
end
if time_outcome~='' then
    local config=plugin.settings:get('read_report');config.enabled=true;config.mode='auto';config.interval_seconds=10
    plugin.settings:set('read_report',config)
    local report=plugin.read_report
    assert(report:maybe_start('synthetic_time'),'CB time reporter did not start')
    if time_outcome=='changed' then control({progress_offset_delta=1}) end
    if time_outcome=='unknown' then control({progress_confirmation='noack'}) end
    report:_tick(report.generation,report.task)
    if time_outcome=='changed' then
        wait(function() return not sync.verified and report.state=='waiting_for_progress' end)
        assert(not plugin.source_dispatch:pending(id),'changed cloud left a time dispatch')
    elseif time_outcome=='unknown' then
        wait(function() return not report.job and plugin.source_dispatch:pending(id) and not sync.verified end)
        for _i=1,4 do UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
        assert(plugin.source_dispatch:pending(id) and not sync.verified,'unconfirmed time was retried')
    else
        wait(function() return report.count==1 and not report.job end)
        assert(sync.verified and not plugin.source_dispatch:pending(id),'confirmed time lost verification')
    end
    report:stop('synthetic_time_done')
end
if close_outcome~='' then
    local config=plugin.settings:get('sync');config.upload_on_close=true;plugin.settings:set('sync',config)
    reader.rolling:onGotoPage(3)
    wait(function() local point=plugin.source_position:current();return point and point.chapter_offset~=original.chapter_offset and sync.dirty end)
    local target=assert(plugin.source_position:current());local closed,posts=false,0
    local request=plugin.client.request
    function plugin.client:request(options)
        if options.url=='https://weread.qq.com/web/book/read' then
            assert(closed and plugin.source_dispatch:pending(id),'close posted before reader closed or journaled')
            local body=client:json_decode(options.body)
            assert(body.rt==0 and body.co==target.chapter_offset,'close did not send the frozen zero-time position')
            posts=posts+1
        end
        return request(self,options)
    end
    if close_outcome=='changed' then control({progress_offset_delta=1}) end
    if close_outcome=='unknown' then control({progress_confirmation='noack'}) end
    reader:onClose(false);closed=true
    wait(function() return not sync.uploading end)
    saved=assert(plugin.settings:get_book(id))
    if close_outcome=='confirmed' then
        assert(posts==1 and not plugin.source_dispatch:pending(id) and not saved.pending_upload_position,
            'confirmed close did not retire its journal')
        local received={};local _,status=http.request{url=settings.mock_endpoint..'/__state',proxy=settings.mock_endpoint,sink=ltn12.sink.table(received)}
        assert(status==200 and client:json_decode(table.concat(received)).progress[id].chapterOffset==target.chapter_offset,
            'cloud did not receive the frozen close position')
    elseif close_outcome=='changed' then
        assert(posts==0 and saved.pending_upload_position and not plugin.source_dispatch:pending(id),
            'changed cloud accepted close or lost local progress')
    else
        assert(posts==1 and plugin.source_dispatch:pending(id) and saved.pending_upload_position
            and saved.pending_upload_reason=='upload_readback_unconfirmed','uncertain close lost journal')
        for _i=1,4 do UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
        assert(posts==1 and plugin.source_dispatch:pending(id),'uncertain close was replayed')
    end
else reader:onClose(false) end
print('\nWEREAD_CB_MANUAL_SYNC='..client:json_encode({result='PASS',choice=true,changed_remote_stopped=true,
    explicit_upload=true,native_point=true,pending_cleared=not noack,journal_cleared=not noack,
    automatic_disabled=not timed,single=single,uncertain=noack,timer_verified=timed,timer_unknown=timer_unknown,
    close_outcome=close_outcome,time_outcome=time_outcome}))
os.exit(0)
