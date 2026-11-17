-- Real-account read-only UI validation. No source text, account data, search
-- term, paths or credentials may be written to output or screenshots.
require('setupkoenv')
local ffi=require('ffi')
local home=assert(os.getenv('KO_HOME'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
Device.screen.shot=function() error('screenshots_disabled',0) end
local Network=require('ui/network/manager');Network.isOnline=function() return true end;Network.isConnected=Network.isOnline
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local json=require('json')
local raw=io.stdin:read(8*1024*1024+1)
local phase='decode'
local navigation_diagnostic='unknown'
local ok,result=pcall(function()
    assert(#raw<=8*1024*1024)
    local input=json.decode(raw);raw=nil
    assert(type(input.cookies)=='table' and input.owner==input.cookies.wr_vid and type(input.chapters)=='table'
        and #input.chapters>0 and #input.chapters<=10000 and type(input.allowed)=='table' and #input.allowed>0 and #input.allowed<=4)
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long);')
    local function anonymous(value)
        local fd=tonumber(ffi.C.memfd_create('weread-book-search-auth',1));assert(fd>=0)
        local bytes='return '..require('dump')(value,nil,true);local at=0
        while at<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+at,#bytes-at));assert(n>0);at=at+n end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies=input.cookies,api_key=''}
    local auth_path=anonymous(auth)
    local Settings=require('weread.lib.settings');local new=Settings.new
    function Settings:new()
        local value=new(self);assert(not value.mock_endpoint)
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local secrets={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _i,key in ipairs(secrets) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(secrets) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value.settings_file=auth_path
        local sync=value:get('sync',{});sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
        local reporting=value:get('read_report',{});reporting.enabled=false;value:set('read_report',reporting)
        local cache=value:get('cache',{});cache.auto_prefetch_next_chapter=false;cache.download_underlines_and_thoughts=false
        cache.download_book_images=false;value:set('cache',cache)
        return value
    end
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local counters=ffi.cast('int *',memory)
    local download_counters=counters+16
    local missing=input.download_missing==true
    if missing then assert(type(input.local_chapter)=='string' and input.local_chapter~=input.chapter) end
    local Protocol=require('weread.lib.protocol');local allowed={}
    for _i,cursor in ipairs(input.allowed) do
        local url='https://weread.qq.com/web/book/search_v2?'..Protocol.sorted_query({bookId=input.book,
            chapterUid=cursor.chapter,keyword=input.keyword,posBegin=cursor.start,posEnd=cursor.finish,mode='scrollDown',count=50})
        allowed[url]=true
    end
    local account_url='https://weread.qq.com/api/userInfo?userVid='..Protocol.urlencode(input.owner)
    local Client=require('weread.lib.client');local request=Client.request
    local gate
    if missing then
        local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
        gate=dofile(fixtures..'note_download_transport.lua'):new({book_id=input.book,owner=input.owner,
            chapters={{chapter_uid=input.chapter}}},'live',download_counters,tonumber(ffi.C.getpid()))
    end
    function Client:request(options)
        if gate and download_counters[5]==1 then
            local kind=gate:classify(self,options)
            local limits={4,1,8}
            if not kind or download_counters[kind]>=limits[kind] or tonumber(ffi.C.getpid())==gate.parent then
                counters[2]=counters[2]+1;error('owner_search_download_scope',0)
            end
            download_counters[0]=download_counters[0]+1;download_counters[kind]=download_counters[kind]+1
            options.sensitive,options.diagnostic_api=true,'note_download_source'
            local body,code,headers,status=request(self,options)
            if tonumber(code)~=200 then download_counters[6]=download_counters[6]+1 end
            return body,code,headers,status
        end
        if options.method~='GET' or options.body~=nil or not options.sensitive or not options.skip_cookie then
            counters[2]=counters[2]+1;error('owner_search_scope',0)
        end
        if options.url==account_url and counters[0]<#input.allowed then counters[0]=counters[0]+1
        elseif allowed[options.url] and counters[1]<#input.allowed then counters[1]=counters[1]+1
        else counters[2]=counters[2]+1;error('owner_search_scope',0) end
        return request(self,options)
    end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start;local workers={}
    function Worker:start(...)
        local returned={start(self,...)}
        if self.job then workers[#workers+1]=self.job.pid end
        return unpack(returned)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local settings=Settings:new();local Content=require('weread.lib.content')
    local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
    local chapter,local_chapter
    for _i,row in ipairs(input.chapters) do
        if tostring(row.chapterUid)==input.chapter then chapter=row end
        if tostring(row.chapterUid)==input.local_chapter then local_chapter=row end
    end
    assert(chapter and (not missing or local_chapter))
    local book={book_id=input.book,bookId=input.book,title='阅读样本',bookVersion=0,chapters=input.chapters,cached_chapters={}}
    local initial_uid=missing and input.local_chapter or input.chapter
    local initial_chapter=missing and local_chapter or chapter
    local initial_source=missing and '<html><body><p>本地测试章节。</p></body></html>' or input.source
    local sources={[initial_uid]=assert(Source.capture(book,initial_chapter,initial_source,'web_xhtml'))}
    local bodies={[initial_uid]=initial_source}
    local file=Content.save_book_epub(settings,book,{initial_chapter},bodies,'owner-search',{},nil,nil,Identity.capture(book),sources)
    book.cached_file=file;book.cached_chapters[initial_uid]=file
    settings:set('books',{[input.book]=book});settings:flush()
    assert(Content.save_catalog_cache(Client:new(settings),settings,book,input.chapters))
    phase='reader'
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local socket=require('socket')
    local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
        document=require('document/documentregistry'):openDocument(file)}
    UI:show(reader);UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
    local plugin=assert(reader.weread)
    local function wait(predicate,seconds)
        local deadline=socket.gettime()+(seconds or 45)
        while not predicate() do
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
            assert(socket.gettime()<deadline,'owner_search_timeout')
        end
    end
    assert(plugin:showEndOfBookDialog(input.book))
    local quick=assert(UI:getTopmostVisibleWidget());local button
    for _i,row in ipairs(quick.buttons) do for _j,item in ipairs(row) do
        if item.text==require('weread.lib.i18n').tr('Search entire book') then button=item end
    end end
    assert(button and button.enabled~=false);button.callback()
    wait(function() return plugin._book_search_owner and plugin._book_search_owner.input end)
    local owner=plugin._book_search_owner;owner.input:setInputText(input.keyword);owner.input.buttons[1][2].callback()
    phase='search'
    local selected,index
    for page=1,#input.allowed do
        wait(function() return owner.state and owner.state.pages==page and not owner.job end)
        for at,hit in ipairs(owner.value) do
            if hit.chapter_uid==input.chapter and hit.start==input.start and hit.finish==input.finish then
                assert(not selected);selected,index=hit,at
            end
        end
        if selected then break end
        assert(not owner.state.finished and owner.menu.item_table[1].text==require('weread.lib.i18n').tr('Load more results'))
        owner.menu:onMenuSelect(owner.menu.item_table[1])
    end
    assert(selected and selected.source_verified==false)
    phase='navigate'
    local target=assert(require('weread.lib.book_search_target').project(input.source,input.book,selected))
    assert(target.chapter_offset==input.start and target.upload_verified==false)
    local row=assert(require('weread.lib.book_search_target').row(input.book,selected))
    local bound=require('weread.lib.book_search_target').resolve(book,file,row,1)
    if missing then assert(not bound.position)
    elseif not bound.position then navigation_diagnostic='bind_failed';error('bind_failed',0) end
    local reported=false
    local report_code='other'
    local translate=require('weread.lib.i18n').tr
    local known_reports={
        [translate('Could not locate this search result in the original text. Try downloading the chapter again.')]='locate_failed',
        [translate('Reading position is temporarily unavailable. Please try again shortly.')]='position_unavailable',
        [translate('Reading position opened, but it could not be saved. Check storage before continuing.')]='save_failed',
    }
    local show_info=plugin.showInfo
    function plugin:showInfo(message,...)
        reported=true;report_code=known_reports[message] or 'other'
        return show_info(self,message,...)
    end
    local source_opened=false
    local open_source=plugin.openSourcePosition
    function plugin:openSourcePosition(...)
        source_opened=true
        return open_source(self,...)
    end
    local prefix=not owner.state.finished and owner.state.pages<128 and 1 or 0
    local item=assert(owner.menu.item_table[index+prefix]);phase='navigate';owner.menu:onMenuSelect(item)
    local cancelled=false
    if missing then
        wait(function() return owner.navigation and owner.navigation.confirm end)
        local confirm=owner.navigation.confirm
        assert(download_counters[0]==0);confirm.cancel_callback();UI:close(confirm)
        assert(not owner.navigation and download_counters[0]==0);cancelled=true
        owner.menu:onMenuSelect(item)
        wait(function() return owner.navigation and owner.navigation.confirm end)
        assert(download_counters[0]==0);confirm=owner.navigation.confirm
        download_counters[5]=1;confirm.ok_callback()
    end
    wait(function()
        if missing then
            local current=require('apps/reader/readerui').instance
            if current and current.weread and current~=reader then reader=current;plugin=current.weread end
        end
        local held=plugin.progress_sync and plugin.progress_sync:current_source_target()
        if owner.navigation and owner.navigation.confirm then navigation_diagnostic='confirm'
        elseif owner.navigation then navigation_diagnostic='working'
        elseif plugin.source_navigation and plugin.source_navigation.state=='ready' then navigation_diagnostic=held and 'ready_target' or 'ready_no_target'
        elseif source_opened then navigation_diagnostic='source_opened'
        elseif reported then navigation_diagnostic=report_code
        else navigation_diagnostic='inactive' end
        return not owner.navigation and plugin.source_navigation and plugin.source_navigation.state=='ready'
            and held and held.chapter_uid==input.chapter and held.chapter_offset==target.chapter_offset
    end,missing and 90 or 15)
    download_counters[5]=0
    assert(reader.document:isXPointerInCurrentPage(assert(plugin.progress_sync.source_anchor).xpointer))
    assert(not plugin.progress_sync.verified and not plugin.read_report.job and counters[2]==0)
    wait(function() for _i,pid in ipairs(workers) do if not require('ffi/util').isSubProcessDone(pid) then return false end end;return true end)
    local value={result='PASS',native_menu=true,search_result_verified=true,source_navigation=true,
        workers_reaped=true,account_gets=tonumber(counters[0]),search_gets=tonumber(counters[1]),denied_requests=tonumber(counters[2])}
    if missing then
        local point=assert(plugin.progress_sync:current_source_target())
        local snapshot=assert(Source.document_metadata(reader.document,input.book,point.chapter_uid,point.render_path))
        assert(snapshot.record.raw_sha256==require('weread.lib.crypto').sha256_hex(input.source))
        local stored=assert(plugin.settings:get_book(input.book))
        assert(stored.cached_chapters[input.chapter]==reader.document.file and reader.document.file~=file)
        assert(download_counters[6]==0 and download_counters[1]>0 and download_counters[2]>0 and download_counters[3]>0)
        local current_cookies=plugin.settings:get('cookies',{})
        local lfs=require('libs/libkoreader-lfs')
        local function audit(dir)
            for entry in lfs.dir(dir) do
                if entry~='.' and entry~='..' and not (dir==home and entry=='plugins') then
                    local path=dir..'/'..entry;local stat=assert(lfs.symlinkattributes(path))
                    if stat.mode=='directory' then audit(path) else
                        assert(stat.mode=='file' and stat.size<=16*1024*1024)
                        local f=assert(io.open(path,'rb'));local bytes=f:read('*a');f:close()
                        for _i,cookies in ipairs({input.cookies,current_cookies}) do
                            for key,secret in pairs(cookies) do
                                if key~='wr_vid' and type(secret)=='string' and #secret>=8 then assert(not bytes:find(secret,1,true)) end
                            end
                        end
                    end
                end
            end
        end
        audit(home)
        value.download_confirmed=true;value.cancel_without_download=cancelled;value.downloaded_source_verified=true
        value.credential_audit=true;value.download_gets=tonumber(download_counters[1])
        value.catalog_posts=tonumber(download_counters[2]);value.content_posts=tonumber(download_counters[3])
    end
    return value
end)
print('\nWEREAD_OWNER_BOOK_SEARCH_UI='..json.encode(ok and result or {result='UNVERIFIED',phase=phase,navigation_diagnostic=navigation_diagnostic}))
os.exit(ok and result.result=='PASS' and 0 or 1)
