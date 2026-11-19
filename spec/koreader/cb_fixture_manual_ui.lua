-- Real ReaderUI manual sync against one scoped self-authored fixture.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local result={result='UNVERIFIED',phase='decode'}
local ok,reason=pcall(function()
    local raw=io.stdin:read(8*1024*1024+1);assert(#raw<=8*1024*1024)
    local input=require('json').decode(raw)
    assert(type(input)=='table' and type(input.book)=='string' and input.book:sub(1,3)=='CB_'
        and type(input.chapter)=='string' and type(input.source)=='string' and type(input.chapters)=='table'
        and type(input.cookies)=='table' and input.cookies.wr_vid == input.owner
        and type(input.first_offset)=='number' and type(input.next_offset)=='number')
    local distance=math.abs(input.next_offset-input.first_offset)
    assert(distance==1 and input.unicode_boundary~=true
        or distance==2 and input.source_format=='web_txt' and input.unicode_boundary==true)
    local reopening=os.getenv('WEREAD_FIXTURE_CB_REOPEN')=='1';local synthetic=os.getenv('WEREAD_FIXTURE_SYNTHETIC')=='1'
    local timed=input.timer==true
    local closing=input.close==true
    local reading_time=input.time==true
    local time_noack=input.time_noack==true
    assert(not time_noack or synthetic and reading_time)
    local cloud=input.cloud==true
    assert((timed and 1 or 0)+(closing and 1 or 0)+(reading_time and 1 or 0)+(cloud and 1 or 0)<=1)
    assert(not (timed or closing or reading_time) or type(input.timer_summary)=='string' and #input.timer_summary>0)
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    if reopening then assert(dofile(fixtures..'offline_network_guard.lua')()) end
    Device.screen.shot=function() error('screenshots_disabled',0) end
    local ffi=require('ffi');pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long);')
    local fd=tonumber(ffi.C.memfd_create('weread-cb-fixture-auth',1));assert(fd>=0)
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies=input.cookies,api_key=''}
    local bytes='return '..require('dump')(auth,nil,true);local at=0
    while at<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+at,#bytes-at));assert(n>0);at=at+n end
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    if input.unicode_boundary then
        local map=assert(require('weread.lib.source_coordinates').build(input.source,{format='web_txt'}))
        local lower=math.min(input.first_offset,input.next_offset)
        local scalar=assert(map:literal_excerpt(lower,1))
        assert(scalar.end_co==lower+2 and #scalar.text==4 and not map:literal_excerpt(lower+1,1))
    end
    local Settings=require('weread.lib.settings');local make_settings=Settings.new
    function Settings:new()
        local value=make_settings(self);assert(synthetic and value.mock_endpoint or not synthetic and not value.mock_endpoint)
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};for _i,key in ipairs({'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}) do
                held[key]=store.data[key];store.data[key]=nil
            end
            local outcome={pcall(flush,store,...)}
            for key,item in pairs(held) do store.data[key]=item end
            assert(outcome[1]);return unpack(outcome,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value.settings_file='/proc/self/fd/'..fd
        local sync=value:get('sync',{});sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
        local report=value:get('read_report',{});report.enabled=false;value:set('read_report',report)
        local cache=value:get('cache',{});cache.auto_prefetch_next_chapter=false;cache.download_underlines_and_thoughts=false
        cache.download_book_images=false;value:set('cache',cache)
        return value
    end
    local Network=require('ui/network/manager');Network.isOnline=function() return not reopening end;Network.isConnected=Network.isOnline
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local Client=require('weread.lib.client');local Protocol=require('weread.lib.protocol');local Cookie=require('weread.lib.cookie')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local counts=ffi.cast('int *',memory);counts[0],counts[1],counts[2]=0,0,0
    local guard=dofile(fixtures..'cb_fixture_manual_guard.lua').new(input,Protocol,Cookie)
    local request=Client.request
    function Client:request(options)
        local kind=not reopening and guard(options,counts[1],function(body) return self:json_decode(body) end)
        if not kind then counts[2]=counts[2]+1;error('fixture_manual_scope',0) end
        if kind=='write' then counts[1]=counts[1]+1
        else
            if counts[0]>=((timed or closing or reading_time) and 110 or 60) then counts[2]=counts[2]+1;error('fixture_manual_scope',0) end
            counts[0]=counts[0]+1
        end
        options.persist_response_cookies=false
        return request(self,options)
    end
    local settings=Settings:new();local client=Client:new(settings);local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+120
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
            assert(socket.gettime()<deadline,'fixture_manual_timeout') end
    end
    local FM=require('apps/filemanager/filemanager');local Reader=require('apps/reader/readerui')
    local function host() FM:showFiles(home);UI:shiftScheduledTasksBy(-1e9);UI:handleInput();return assert(FM.instance.weread) end
    if reopening then
        result.phase='reopen';local saved=assert(settings:get_book(input.book));local main=host()
        main.isNetworkOnline=function() return false end;main.isNetworkConnected=main.isNetworkOnline
        assert(main:startBookReading(saved))
        wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==input.book end)
        local plugin=Reader.instance.weread;local state=assert(plugin.settings:get_book(input.book))
        if time_noack then
            assert(plugin.source_dispatch:pending(input.book) and not plugin.progress_sync.verified
                and counts[0]==0 and counts[1]==0 and counts[2]==0)
            result={result='PASS',fresh_process=true,offline=true,journal_pending=true,requests=0};return
        end
        if cloud then
            assert(state.pending_upload_position and state.pending_upload_position.source_position
                and state.pending_upload_position.source_position.chapter_offset==input.next_offset
                and not plugin.source_dispatch:pending(input.book) and not plugin.progress_sync.verified
                and counts[0]==0 and counts[1]==0 and counts[2]==0)
            result={result='PASS',fresh_process=true,offline=true,pending_preserved=true,journal_cleared=true,requests=0};return
        end
        assert(not state.pending_upload_position and not plugin.source_dispatch:pending(input.book)
            and not plugin.progress_sync.verified and counts[0]==0 and counts[1]==0 and counts[2]==0)
        result={result='PASS',fresh_process=true,offline=true,pending_cleared=true,journal_cleared=true,requests=0};return
    end
    result.phase='prepare'
    local Content=require('weread.lib.content');local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
    local book={book_id=input.book,bookId=input.book,bookVersion=input.book_version or 0,title='合成测试书',cached_chapters={}}
    local target
    for _i,chapter in ipairs(input.chapters) do if tostring(chapter.chapterUid)==input.chapter then
        assert(not target and chapter.chapterIdx==input.chapter_idx);target=chapter end end
    assert(target and type(target.wordCount)=='number' and target.wordCount>0)
    local source_format=input.source_format or 'web_xhtml'
    assert(source_format=='web_xhtml' or source_format=='web_txt')
    local source=assert(Source.capture(book,target,input.source,source_format))
    local rendered=source_format=='web_txt' and Content.txt_to_xhtml(input.source) or input.source
    local file=assert(Content.save_book_epub(settings,book,{target},{[input.chapter]=rendered},'fixture-manual',{},nil,nil,
        Identity.capture(book),{[input.chapter]=source}))
    book.cached_file=file;book.cached_chapters[input.chapter]=file;book.chapters=input.chapters
    assert(Content.save_catalog_cache(client,settings,book,input.chapters))
    settings:set('books',{[input.book]=book});settings:flush()
    local main=host();assert(main.library_db:putChapters(input.book,input.chapters));main:openChapter(book,target)
    wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==input.book end)
    local reader=Reader.instance;local plugin=reader.weread
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    wait(function() local point=plugin.source_position:current();return point and point.chapter_uid==input.chapter end)
    local point=assert(plugin.source_position:current());point.chapter_offset=input.next_offset
    local landed=false;assert(plugin:openSourcePosition(point,function(value) landed=value~=nil end))
    wait(function() return landed and plugin.source_position:current() and plugin.source_position:current().chapter_offset==input.next_offset end)
    result.phase='choice'
    local sync=plugin.progress_sync;local choice,box,notice
    local show=UI.show
    function UI:show(widget,...)
        if choice and widget.cancel_callback==choice.keep_local then box=widget end
        return show(self,widget,...)
    end
    local old_choice=sync.on_choice;sync.on_choice=function(value) choice=value;old_choice(value) end
    sync.notify=function(code,data) notice={code=code,data=data} end
    assert(sync:sync_now());wait(function() return choice and box end)
    assert(choice.remote_position.chapter_offset==input.first_offset and choice.local_position.source_position.chapter_offset==input.next_offset)
    if cloud then
        local account=assert(plugin.library_db:accountKey())
        assert(plugin.settings:patch_reading_state(input.book,{pending_upload_position={book_id=input.book,chapter_uid=input.chapter,
            chapter_offset=input.next_offset,percent=12},pending_upload_reason='synthetic_pending',pending_upload_account=account}))
    end
    UI:close(box)
    if cloud then
        result.phase='cloud';choice.use_remote()
        wait(function() local current=plugin.source_position:current()
            local state=plugin.settings:get_book(input.book)
            return current and current.chapter_offset==input.first_offset and sync.source_anchor
                and not plugin.cloud_source_request and state and state.cb_cloud_view_resume end)
        local state=assert(plugin.settings:get_book(input.book))
        assert(not sync.verified and state.pending_upload_position and state.pending_upload_position.source_position
            and state.pending_upload_position.source_position.chapter_offset==input.next_offset
            and not plugin.source_dispatch:pending(input.book) and counts[1]==0 and counts[2]==0)
        plugin:onFlushSettings();reader:onClose(false)
        result={result='PASS',cloud_choice=true,pending_preserved=true,upload_disabled=true,writes=0,denied=0};return
    end
    choice.keep_local();result.phase='upload'
    wait(function() return notice~=nil end)
    if input.armed==false then
        local state=assert(plugin.settings:get_book(input.book))
        assert(notice.code=='upload_unconfirmed' and counts[1]==0 and counts[2]==1 and not sync.verified
            and state.pending_upload_position and plugin.source_dispatch:pending(input.book),'manual dry run did not block write')
        result={result='DRY_RUN',native_choice=true,write_blocked=true,writes=0,denied=1};return
    end
    assert(notice.code=='upload_success' and counts[1]==2 and counts[2]==0,'manual fixture upload failed')
    local saved=assert(plugin.settings:get_book(input.book))
    assert(not saved.pending_upload_position and not plugin.source_dispatch:pending(input.book) and sync.verified)
    if timed or closing or reading_time then
        result.phase=timed and 'timer' or closing and 'close' or 'time'
        local timer=sync.interval;local clock=100;timer.now=function() return clock end
        local config=plugin.settings:get('sync');config.upload_interval_minutes=timed and 1 or 0
        config.upload_on_close=closing;plugin.settings:set('sync',config)
        local previous=assert(plugin.source_position:current());previous.chapter_offset=input.first_offset
        local returned=false;assert(plugin:openSourcePosition(previous,function(value) returned=value~=nil end))
        wait(function() local current=plugin.source_position:current()
            return returned and current and current.chapter_offset==input.first_offset and sync.dirty and (not timed or timer.task) end)
        if timed then clock=timer.due;UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
        elseif closing then reader:onClose(false)
        else
            local config_report=plugin.settings:get('read_report')
            config_report.enabled=true;config_report.mode='auto';config_report.interval_seconds=10
            plugin.settings:set('read_report',config_report)
            local report=plugin.read_report;assert(report:maybe_start('fixture_time'))
            UI:unschedule(report.task)
            if time_noack then
                local http,ltn12=require('socket.http'),require('ltn12');local body=client:json_encode({progress_confirmation='noack'});local output={}
                local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
                    headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)},source=ltn12.source.string(body),sink=ltn12.sink.table(output)}
                assert(code==200)
            end
            socket.sleep(10.05)
            report:_tick(report.generation,report.task)
            wait(function() return not report.job and (time_noack and report.state=='error' or not time_noack and report.count==1) end)
            if time_noack then assert(report.last_error_kind=='unconfirmed','unconfirmed time was not reported') end
            report:stop('fixture_time_done')
        end
        wait(function() return not timer.cycle and not sync.uploading end)
        saved=assert(plugin.settings:get_book(input.book))
        if time_noack then
            assert(counts[1]==3 and counts[2]==0 and not sync.verified and plugin.source_dispatch:pending(input.book),
                'unconfirmed time did not retain its journal')
        else
            assert(counts[1]==3 and counts[2]==0 and sync.verified==not closing and (closing or not sync.dirty) and not timer.task
                and not saved.pending_upload_position and not plugin.source_dispatch:pending(input.book),'automatic fixture upload failed')
        end
    end
    plugin:onFlushSettings();if not closing then reader:onClose(false) end
    result={result='PASS',native_choice=true,actual_source=true,upload_confirmed=true,pending_cleared=not time_noack,
        journal_cleared=not time_noack,automatic_disabled=not (timed or closing or reading_time),timer_verified=timed,writes=tonumber(counts[1]),denied=tonumber(counts[2])}
    if closing then result.close_verified=true end
    if time_noack then result.time_unconfirmed=true elseif reading_time then result.time_verified=true end
end)
if not ok then result.result='UNVERIFIED';result.failure_line=tonumber(type(reason)=='string' and reason:match('cb_fixture_manual_ui%.lua:(%d+):')) or 0 end
print('\nWEREAD_CB_FIXTURE_MANUAL_UI='..require('json').encode(result))
os.exit((result.result=='PASS' or result.result=='DRY_RUN') and 0 or 1)
