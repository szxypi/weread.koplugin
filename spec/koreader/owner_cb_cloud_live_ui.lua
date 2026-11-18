-- Real-source read-only UI check; inputs and files exist only in memory/tmpfs.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local result={result='UNVERIFIED',phase='decode'}
local ok,reason=pcall(function()
    local raw=io.stdin:read(8*1024*1024+1);assert(#raw<=8*1024*1024)
    local input=require('json').decode(raw)
    assert(type(input.book)=='string' and input.book:sub(1,3)=='CB_' and type(input.chapter)=='string'
        and type(input.source)=='string' and type(input.offset)=='number' and type(input.percent)=='number')
    local target_offset=input.target_offset or input.offset
    assert(type(target_offset)=='number' and target_offset>=input.offset and target_offset-input.offset<=1024)
    local local_chapter=input.chapter=='999999999' and '999999998' or '999999999'
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local reopening=os.getenv('WEREAD_OWNER_CB_REOPEN')=='1'
    local synthetic=os.getenv('WEREAD_OWNER_SYNTHETIC')=='1'
    if reopening or synthetic then assert(dofile(fixtures..'offline_network_guard.lua')()) end
    Device.screen.shot=function() error('screenshots_disabled',0) end
    assert(type(input.cookies)=='table' and type(input.owner)=='string' and input.cookies.wr_vid == input.owner)
    local ffi=require('ffi');pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long); int getpid(void);')
    local fd=tonumber(ffi.C.memfd_create('weread-cb-cloud-auth',1));assert(fd>=0)
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies=input.cookies,api_key=''}
    local bytes='return '..require('dump')(auth,nil,true);local at=0
    while at<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+at,#bytes-at));assert(n>0);at=at+n end
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local Settings=require('weread.lib.settings');local new=Settings.new
    function Settings:new()
        local value=new(self);assert(not value.mock_endpoint);local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local secrets={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _i,key in ipairs(secrets) do held[key]=store.data[key];store.data[key]=nil end
            local flushed={pcall(flush,store,...)}
            for _i,key in ipairs(secrets) do store.data[key]=held[key] end
            assert(flushed[1]);return unpack(flushed,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value.settings_file='/proc/self/fd/'..fd
        local sync=value:get('sync',{});sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
        local reporting=value:get('read_report',{});reporting.enabled=false;value:set('read_report',reporting)
        local cache=value:get('cache',{});cache.auto_prefetch_next_chapter=false;cache.download_underlines_and_thoughts=false
        cache.download_book_images=false;value:set('cache',cache)
        return value
    end
    local Network=require('ui/network/manager');Network.isOnline=function() return not reopening end;Network.isConnected=Network.isOnline
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local Content=require('weread.lib.content');local Source=require('weread.lib.position_source')
    local Identity=require('weread.lib.book_file_identity');local settings=require('weread.lib.settings'):new()
    local Client=require('weread.lib.client')
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local socket=require('socket');local Reader=require('apps/reader/readerui')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local requests=ffi.cast('int *',memory);requests[0]=0
    local request_original=Client.request;local parent=tonumber(ffi.C.getpid())
    local Protocol=require('weread.lib.protocol');local Cookie=require('weread.lib.cookie')
    local guard=dofile(fixtures..'cb_cloud_live_guard.lua').new(input,Protocol,Cookie,parent)
    function Client:request(options)
        local allowed=guard(options,requests[0],tonumber(ffi.C.getpid()),function(body) return self:json_decode(body) end,reopening)
        if not allowed then requests[1]=requests[1]+1;error('owner_cb_cloud_scope',0) end
        requests[0]=requests[0]+1
        if synthetic then
            local point={bookId=input.book,chapterUid=input.chapter,chapterOffset=input.offset,progress=input.percent}
            local before={book=point}
            local reader={bookInfo={bookId=input.book},currentChapter={chapterUid=input.chapter},progress=before,psvts='synthetic'}
            local data=requests[0]==2 and ('window.__INITIAL_STATE__='..self:json_encode({reader=reader})..';(function(){})();')
                or (requests[0]==1 or requests[0]==6) and self:json_encode(before) or 'synthetic-shard'
            options.sink(data);options.sink(nil);return 1,200,{}
        end
        return request_original(self,options)
    end
    if synthetic then Content.decode_content_shards=function() return input.source end end
    local function wait(predicate)
        local deadline=socket.gettime()+120
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
            assert(socket.gettime()<deadline,'ui_timeout') end
    end
    local FM=require('apps/filemanager/filemanager')
    local function host() FM:showFiles(home);UI:shiftScheduledTasksBy(-1e9);UI:handleInput();return assert(FM.instance.weread) end
    local single=os.getenv('WEREAD_OWNER_SINGLE')=='1'
    if reopening then
        result.phase='reopen';local book=assert(settings:get_book(input.book))
        local path=assert(single and book.cached_chapters[input.chapter] or book.cached_full_book)
        local file=assert(io.open(home..'/resume-xpointer.txt','rb'));local xpointer=file:read('*a');file:close()
        local main=host();main.isNetworkOnline=function() return false end;main.isNetworkConnected=main.isNetworkOnline
        assert(main:startBookReading(book))
        wait(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==path
            and Reader.instance.weread and Reader.instance.document:isXPointerInCurrentPage(xpointer) end)
        local plugin=Reader.instance.weread;local saved=assert(plugin.settings:get_book(input.book))
        assert(saved.pending_upload_position.chapter_uid==local_chapter and saved.pending_upload_reason=='synthetic_pending')
        assert(not plugin.progress_sync.verified and requests[0]==0 and requests[1]==0)
        plugin:onFlushSettings();Reader.instance:onClose(false)
        result={result='PASS',fresh_process=true,offline=true,pending_preserved=true,upload_disabled=true,requests=0};return
    end
    result.phase='prepare'
    local book={book_id=input.book,bookId=input.book,bookVersion=0,title='合成标题',cached_chapters={}}
    local chapters={{chapterUid=local_chapter,title='合成章节'},{chapterUid=input.chapter,title='目标章节'}}
    local bodies={[local_chapter]='<html><body><p>合成本地起始章节。</p></body></html>',[input.chapter]=input.source}
    local sources={}
    for _i,chapter in ipairs(chapters) do
        local uid=chapter.chapterUid;sources[uid]=assert(Source.capture(book,chapter,bodies[uid],'web_xhtml'))
        if single then
            book.cached_chapters[uid]=assert(Content.save_book_epub(settings,book,{chapter},bodies,'owner-cb-'..uid,{},nil,nil,
                Identity.capture(book),{[uid]=sources[uid]}))
        end
    end
    if single then book.cached_file=book.cached_chapters[local_chapter]
    else
        book.cached_full_book=assert(Content.save_book_epub(settings,book,chapters,bodies,'owner-cb-full',{},nil,nil,
            Identity.capture(book),sources));book.cached_file=book.cached_full_book
    end
    book.chapters=chapters;settings:set('books',{[input.book]=book});settings:set('sync',{pull_on_open=false,upload_on_close=false})
    local cache=settings:get('cache',{});cache.auto_prefetch_next_chapter=false;settings:set('cache',cache)
    local reporting=settings:get('read_report',{});reporting.enabled=false;settings:set('read_report',reporting);settings:flush()
    result.phase='navigate'
    local main=host()
    if single then main:openChapter(book,chapters[1]) else assert(main:startBookReading(book)) end
    wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==input.book end)
    local reader=Reader.instance;local plugin=reader.weread
    assert(not single or reader.document.file==book.cached_chapters[local_chapter])
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local account=assert(plugin.library_db:accountKey())
    assert(plugin.settings:patch_reading_state(input.book,{pending_upload_position={book_id=input.book,chapter_uid=local_chapter,
        chapter_offset=19,percent=12},pending_upload_reason='synthetic_pending',pending_upload_account=account}))
    assert(plugin:showCloudSourcePosition())
    local original=reader
    wait(function()
        if Reader.instance and Reader.instance.weread then reader=Reader.instance;plugin=reader.weread end
        local held=plugin.source_position and plugin.source_position:current()
        return held and held.chapter_uid==input.chapter and held.chapter_offset==target_offset
            and not plugin.cloud_source_request and not plugin.cloud_source_incoming
    end)
    assert(not single or reader~=original)
    local anchor=assert(plugin.progress_sync.source_anchor)
    assert(reader.document:isXPointerInCurrentPage(anchor.xpointer) and not plugin.progress_sync.verified)
    local saved=assert(plugin.settings:get_book(input.book))
    assert(saved.pending_upload_position.chapter_uid==local_chapter and saved.pending_upload_reason=='synthetic_pending')
    local output=assert(io.open(home..'/resume-xpointer.txt','wb'));assert(output:write(anchor.xpointer));assert(output:close())
    plugin:onFlushSettings();reader:onClose(false);assert(requests[0]==6 and requests[1]==0)
    result={result='PASS',native_navigation=true,pending_preserved=true,upload_disabled=true,requests=6,denied=0}
end)
if not ok then result.result='UNVERIFIED';result.failure_line=tonumber(type(reason)=='string' and reason:match('owner_cb_cloud_view_ui%.lua:(%d+):')) or 0 end
print('\nWEREAD_OWNER_CB_CLOUD_LIVE='..require('json').encode(result))
os.exit(result.result=='PASS' and 0 or 1)
