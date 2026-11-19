-- One isolated CB fixture, native page bookmark and independent host readback.
require('setupkoenv')
local ffi,Json=require('ffi'),require('json')
local home=assert(os.getenv('KO_HOME'));local result={result='UNVERIFIED',phase='decode'}
local input,counts,plugin,reader
local ok,reason=pcall(function()
    local length=tonumber(assert(io.stdin:read('*l')));assert(length and length>0 and length<=8*1024*1024)
    input=Json.decode(assert(io.stdin:read(length)))
    assert(type(input)=='table' and type(input.book)=='string' and input.book:match('^CB_[%w]+$')
        and type(input.chapter)=='string' and type(input.source)=='string' and type(input.chapters)=='table'
        and type(input.cookies)=='table' and input.cookies.wr_vid == input.owner and type(input.native)=='table'
        and input.native.vid==input.owner and type(input.armed)=='boolean' and type(input.body)=='table'
        and type(input.first)=='number' and input.first>=0
        and type(input.token)=='string' and input.token:match('^[a-f0-9]+$') and #input.token==32)
    local reopen=os.getenv('WEREAD_CB_BOOKMARK_REOPEN')=='1'
    local synthetic=os.getenv('WEREAD_FIXTURE_SYNTHETIC')=='1'
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    if reopen then assert(dofile(fixtures..'offline_network_guard.lua')()) end
    Device.screen.shot=function() error('screenshots_disabled',0) end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long);')
    local function memfile(name,value)
        local fd=tonumber(ffi.C.memfd_create(name,1));assert(fd>=0)
        local bytes='return '..require('dump')(value,nil,true);local at=0
        while at<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+at,#bytes-at));assert(n>0);at=at+n end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies=input.cookies,api_key=''}
    local auth_path=memfile('cb-highlight-web',auth)
    local native={};for key,value in pairs(input.native) do native[key]=value end
    native.epoch=1;native.verified_at=os.time();native.book_count=0
    local native_path=memfile('cb-highlight-native',{revision=1,authorization=native})
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
    function NativeStore:new(settings,dependencies) local value=make_native(self,settings,dependencies);value.path=native_path;return value end
    local Network=require('ui/network/manager');Network.isOnline=function() return not reopen end;Network.isConnected=Network.isOnline
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local Client,Protocol,Cookie=require('weread.lib.client'),require('weread.lib.protocol'),require('weread.lib.cookie')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counts=ffi.cast('int *',memory)
    local readonly={};for key,value in pairs(input) do readonly[key]=value end;readonly.armed=false
    local web_guard=dofile(fixtures..'cb_initial_fixture_ui_guard.lua').new(readonly,Protocol,Cookie)
    local base='https://i.weread.qq.com'
    local reads={[base..'/book/bookmarklist?bookId='..input.book..'&synckey=0']=true,
        [base..'/review/list?bookId='..input.book..'&listType=11&listMode=0&mine=1&synckey=0&count=20']=true,
        [base..'/book/info?bookId='..input.book]=true}
    local gate;local request=Client.request;local parent=tonumber(ffi.C.getpid())
    function Client:request(options)
        if reopen then counts[2]=counts[2]+1;error('cb_bookmark/offline',0) end
        local headers=options.headers or {};local native_ok=options.sensitive==true and options.skip_cookie==true
            and headers.vid==input.owner and headers.accessToken==input.native.accessToken and not headers.Cookie
        if native_ok and options.method=='GET' and options.body==nil and reads[options.url] and counts[0]<80 then
            counts[0]=counts[0]+1;options.persist_response_cookies=false;return request(self,options)
        end
        local operation=({[base..'/book/addBookmark']='bookmark_create',[base..'/book/removeBookmark']='bookmark_delete'})[options.url]
        if native_ok and options.method=='POST' and operation and type(options.body)=='string' and gate then
            assert(tonumber(ffi.C.getpid())~=parent,'bookmark write on UI thread')
            local body=self:json_decode(options.body)
            if not gate:claim(operation,body) then counts[3]=counts[3]+1;error('cb_bookmark/dry_run',0) end
            counts[1]=counts[1]+1;assert(counts[1]<=2);options.persist_response_cookies=false;return request(self,options)
        end
        if web_guard(options,0,function(body) return self:json_decode(body) end)=='read' and counts[0]<80 then
            counts[0]=counts[0]+1;options.persist_response_cookies=false;return request(self,options)
        end
        counts[2]=counts[2]+1;error('cb_bookmark/scope',0)
    end
    local settings=Settings:new();local client=Client:new(settings);local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+120
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
            assert(socket.gettime()<deadline,'cb_bookmark/timeout') end
    end
    local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
    local function host() FM:showFiles(home);UI:shiftScheduledTasksBy(-1e9);UI:handleInput();return assert(FM.instance.weread) end
    local Service=require('weread.lib.mark_edit_service')
    if reopen then
        result.phase='reopen';local saved=assert(settings:get_book(input.book));local main=host()
        main.isNetworkOnline=function() return false end;main.isNetworkConnected=main.isNetworkOnline
        assert(main:startBookReading(saved));wait(function() return Reader.instance and Reader.instance.weread end)
        plugin=Reader.instance.weread
        assert(Service.new_journal(plugin.library_db,plugin.client):read().phase=='idle')
        local cache=assert(Service.new_cache(plugin.library_db,plugin.client):read(input.book))
        assert(#cache.updated==0 and counts[0]==0 and counts[1]==0 and counts[2]==0)
        result={result='PASS',fresh_offline=true,requests=0,pending_cleared=true};return
    end
    result.phase='prepare'
    local Content,Source,Identity=require('weread.lib.content'),require('weread.lib.position_source'),require('weread.lib.book_file_identity')
    local book={book_id=input.book,bookId=input.book,bookVersion=input.book_version,title='Synthetic fixture',cached_chapters={}}
    local target
    for _i,chapter in ipairs(input.chapters) do if tostring(chapter.chapterUid)==input.chapter then
        assert(not target and chapter.chapterIdx==input.chapter_idx);target=chapter end end
    assert(target and type(target.wordCount)=='number' and target.wordCount>0)
    local format=input.source_format or 'web_xhtml';assert(format=='web_xhtml' or format=='web_txt')
    local source=assert(Source.capture(book,target,input.source,format))
    local rendered=format=='web_txt' and Content.txt_to_xhtml(input.source) or input.source
    local file=assert(Content.save_book_epub(settings,book,{target},{[input.chapter]=rendered},'fixture-highlight',{},nil,nil,
        Identity.capture(book),{[input.chapter]=source}))
    book.cached_file=file;book.cached_chapters[input.chapter]=file;book.chapters=input.chapters
    assert(Content.save_catalog_cache(client,settings,book,input.chapters));settings:set('books',{[input.book]=book});settings:flush()
    local main=host();assert(main.library_db:putChapters(input.book,input.chapters))
    gate=dofile(fixtures..'native_highlight_trial_gate.lua'):new({permit_writes=input.armed,book_id=input.book,
        bookmarks=true,original_ids={},create_body=input.body},main.library_db,main.client,home)
    main:openChapter(book,target);wait(function() return Reader.instance and Reader.instance.weread end)
    reader=Reader.instance;plugin=reader.weread
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local index=assert(require('weread.lib.source_dom').open(reader.document,input.book,input.chapter))
    local first=assert(index:locate(input.first))
    reader:handleEvent(require('ui/event'):new('SetViewMode','scroll'))
    reader.rolling:onGotoXPointer(first.xpointer);reader.document:clearSelection();UI:forceRePaint()
    local function viewport()
        local location=assert(require('weread.lib.source_context').location(reader.document,reader.view.view_mode));local xp=location.xpointer
        if not xp:find('/text()',1,true) then xp=assert(reader.document:getNextVisibleChar(xp));assert(reader.document:isXPointerInCurrentPage(xp)) end
        return assert(index:capture(xp)).co
    end
    assert(reader.view.view_mode=='scroll' and viewport()==input.first,'cb_bookmark/viewport')
    local tr=require('weread.lib.plugin_util').tr;local invoked=false
    for _i,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Save cloud bookmark') then item.callback();invoked=true;break end end
    assert(invoked,'cb_bookmark/menu')
    local owner;wait(function() owner=plugin._selection_thought_owner or owner;return owner and (owner.reference or owner.error) end)
    assert(owner.reference and owner.reference.range==input.body.range and owner.reference.markText==input.body.markText,'cb_bookmark/source')
    local function row(label) for _i,item in ipairs(owner.menu.item_table) do if item.text==tr(label) then item.callback();return end end;error('cb_bookmark/action',0) end
    local function tap(key) UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key)):onTapSelectButton() end
    local function submit()
        wait(function() return not owner.mark_editor or owner.mark_editor.service.preview end);assert(owner.mark_editor)
        tap('confirm_highlight_change');wait(function() return not owner.mark_editor end)
        local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
    end
    local function acknowledge(value)
        io.write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_STEP='..Json.encode(value)..'\n');io.flush()
        local reply=Json.decode(assert(io.stdin:read('*l')));assert(reply.seq==value.seq and reply.ok==true)
        if value.created_id then assert(reply.created_id==value.created_id) end
    end
    result.phase='create';row('Save cloud bookmark');submit()
    local journal=Service.new_journal(plugin.library_db,plugin.client)
    if not input.armed then
        local blocked=gate:read();assert(blocked.phase=='blocked' and blocked.posts==0 and counts[1]==0 and counts[3]==1
            and journal:read().phase=='pending')
        acknowledge({seq=0,preview=blocked.preview})
        result={result='DRY_RUN',write_blocked=true,writes=0,denied=0};return
    end
    assert(gate:read().phase=='create_pending' and journal:read().phase=='idle')
    local cache=Service.new_cache(plugin.library_db,plugin.client);local saved=assert(cache:read(input.book));assert(#saved.updated==1)
    local created=saved.updated[1].bookmarkId;acknowledge({seq=1,created_id=created});gate:advance(created)
    require('weread.ui.selection_thought').cancel(plugin);assert(plugin:showMyCloudBookmarks(input.book));owner=assert(plugin._my_marks_owner)
    local item;for _i,value in ipairs(owner.menu.item_table) do if value.my_note_id==created then item=value end end
    assert(item);item.callback();tap('open_bookmark')
    wait(function() return not plugin._my_marks_owner and not plugin._read_resume_active and not owner.navigation end)
    assert(viewport()==input.first,'cb_bookmark/navigation')
    assert(plugin:showMyCloudBookmarks(input.book));owner=assert(plugin._my_marks_owner)
    item=nil;for _i,value in ipairs(owner.menu.item_table) do if value.my_note_id==created then item=value end end
    assert(item);item.callback();result.phase='delete';tap('delete_bookmark');submit()
    assert(gate:read().phase=='delete_pending' and journal:read().phase=='idle');acknowledge({seq=2,created_id=created})
    saved=assert(cache:read(input.book));assert(#saved.updated==0 and counts[1]==2 and counts[2]==0)
    plugin:cancelMyCloudMarks();plugin:onFlushSettings();reader:onClose(false)
    result={result='PASS',native_controls=true,source_verified=true,writes=2,denied=0,pending_cleared=true}
end)
if not ok then result.result='UNVERIFIED';result.failure_line=tonumber(type(reason)=='string' and reason:match('cb_fixture_bookmark_ui%.lua:(%d+):')) or 0 end
if input and type(input.token)=='string' and input.token:match('^[a-f0-9]+$') and #input.token==32 then
    io.write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_RESULT='..Json.encode(result)..'\n');io.flush()
end
os.exit((result.result=='PASS' or result.result=='DRY_RUN') and 0 or 1)
