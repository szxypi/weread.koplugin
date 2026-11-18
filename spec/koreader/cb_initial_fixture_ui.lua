-- Scoped first sync for one freshly uploaded, self-authored imported book.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local result={result='UNVERIFIED',phase='decode'}
local ok,reason=pcall(function()
    local raw=io.stdin:read(8*1024*1024+1);assert(#raw<=8*1024*1024)
    local input=require('json').decode(raw)
    assert(type(input)=='table' and type(input.book)=='string' and input.book:sub(1,3)=='CB_'
        and type(input.chapter)=='string' and type(input.source)=='string' and type(input.chapters)=='table'
        and type(input.cookies)=='table' and input.cookies.wr_vid == input.owner and type(input.native)=='table'
        and input.native.vid==input.owner and type(input.offset)=='number' and type(input.armed)=='boolean')
    local reopening=os.getenv('WEREAD_CB_INITIAL_FIXTURE_REOPEN')=='1'
    local synthetic=os.getenv('WEREAD_FIXTURE_SYNTHETIC')=='1'
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    if reopening then assert(dofile(fixtures..'offline_network_guard.lua')()) end
    Device.screen.shot=function() error('screenshots_disabled',0) end
    local ffi=require('ffi');pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long);')
    local function memfile(name,value)
        local fd=tonumber(ffi.C.memfd_create(name,1));assert(fd>=0)
        local bytes='return '..require('dump')(value,nil,true);local at=0
        while at<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+at,#bytes-at));assert(n>0);at=at+n end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies=input.cookies,api_key=''}
    local auth_path=memfile('weread-first-web',auth)
    local native={};for key,value in pairs(input.native) do native[key]=value end
    native.epoch=1;native.verified_at=os.time();native.book_count=0
    local native_path=memfile('weread-first-native',{revision=1,authorization=native})
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
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
        value.settings_file=auth_path
        local sync=value:get('sync',{});sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
        local report=value:get('read_report',{});report.enabled=false;value:set('read_report',report)
        local cache=value:get('cache',{});cache.auto_prefetch_next_chapter=false;cache.download_underlines_and_thoughts=false
        cache.download_book_images=false;value:set('cache',cache)
        return value
    end
    local NativeStore=require('weread.lib.native_credentials');local make_native=NativeStore.new
    function NativeStore:new(settings,dependencies)
        local value=make_native(self,settings,dependencies);value.path=native_path;return value
    end
    local Network=require('ui/network/manager');Network.isOnline=function() return not reopening end;Network.isConnected=Network.isOnline
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local Client=require('weread.lib.client');local Protocol=require('weread.lib.protocol');local Cookie=require('weread.lib.cookie')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local counts=ffi.cast('int *',memory);counts[0],counts[1],counts[2]=0,0,0
    local guard=dofile(fixtures..'cb_initial_fixture_ui_guard.lua').new(input,Protocol,Cookie)
    local request=Client.request
    function Client:request(options)
        local kind=not reopening and guard(options,counts[1],function(body) return self:json_decode(body) end)
        if not kind then counts[2]=counts[2]+1;error('cb_first_fixture_scope',0) end
        if kind=='write' then counts[1]=counts[1]+1
        else if counts[0]>=80 then counts[2]=counts[2]+1;error('cb_first_fixture_scope',0) end;counts[0]=counts[0]+1 end
        options.persist_response_cookies=false
        return request(self,options)
    end
    local settings=Settings:new();local client=Client:new(settings);local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+120
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
            assert(socket.gettime()<deadline,'cb_first_fixture_timeout') end
    end
    local FM=require('apps/filemanager/filemanager');local Reader=require('apps/reader/readerui')
    local function host() FM:showFiles(home);UI:shiftScheduledTasksBy(-1e9);UI:handleInput();return assert(FM.instance.weread) end
    if reopening then
        result.phase='reopen';local saved=assert(settings:get_book(input.book));local main=host()
        main.isNetworkOnline=function() return false end;main.isNetworkConnected=main.isNetworkOnline
        assert(main:startBookReading(saved))
        wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==input.book end)
        local plugin=Reader.instance.weread;local state=assert(plugin.settings:get_book(input.book))
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
    local source=assert(Source.capture(book,target,input.source,'web_xhtml'))
    local file=assert(Content.save_book_epub(settings,book,{target},{[input.chapter]=input.source},'fixture-first',{},nil,nil,
        Identity.capture(book),{[input.chapter]=source}))
    book.cached_file=file;book.cached_chapters[input.chapter]=file;book.chapters=input.chapters
    assert(Content.save_catalog_cache(client,settings,book,input.chapters))
    settings:set('books',{[input.book]=book});settings:flush()
    local main=host();assert(main.library_db:putChapters(input.book,input.chapters));main:openChapter(book,target)
    wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==input.book end)
    local reader=Reader.instance;local plugin=reader.weread
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    wait(function() local point=plugin.source_position:current();return point and point.chapter_uid==input.chapter end)
    local point=assert(plugin.source_position:current());point.chapter_offset=input.offset
    local landed=false;assert(plugin:openSourcePosition(point,function(value) landed=value~=nil end))
    wait(function() return landed and plugin.source_position:current() and plugin.source_position:current().chapter_offset==input.offset end)
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
    assert(choice.initialize_cloud and not choice.use_remote and choice.local_position.source_position.chapter_offset==input.offset)
    UI:close(box);choice.initialize();result.phase='upload'
    wait(function() return notice~=nil end)
    local saved=assert(plugin.settings:get_book(input.book))
    if not input.armed then
        assert(notice.code=='upload_unconfirmed' and counts[1]==0 and counts[2]==1 and not sync.verified
            and saved.pending_upload_position and plugin.source_dispatch:pending(input.book),'first dry run did not block write')
        result={result='DRY_RUN',native_choice=true,write_blocked=true,writes=0,denied=1};return
    end
    assert(notice.code=='upload_success' and counts[1]==1 and counts[2]==0 and sync.verified
        and not saved.pending_upload_position and not plugin.source_dispatch:pending(input.book),'first fixture upload failed')
    plugin:onFlushSettings();reader:onClose(false)
    result={result='PASS',native_choice=true,actual_source=true,upload_confirmed=true,pending_cleared=true,
        journal_cleared=true,automatic_disabled=true,writes=tonumber(counts[1]),denied=tonumber(counts[2])}
end)
if not ok then result.result='UNVERIFIED';result.failure_line=tonumber(type(reason)=='string' and reason:match('cb_initial_fixture_ui%.lua:(%d+):')) or 0 end
print('\nWEREAD_CB_INITIAL_FIXTURE_UI='..require('json').encode(result))
os.exit((result.result=='PASS' or result.result=='DRY_RUN') and 0 or 1)
