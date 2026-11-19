-- One isolated CB fixture, native highlight save/delete and host readback.
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
        and type(input.first)=='number' and type(input.last)=='number' and input.first<input.last
        and type(input.token)=='string' and input.token:match('^[a-f0-9]+$') and #input.token==32)
    local reopen=os.getenv('WEREAD_CB_HIGHLIGHT_REOPEN')=='1'
    local synthetic=os.getenv('WEREAD_FIXTURE_SYNTHETIC')=='1'
    local styles=input.styles==true
    local palette=input.palette==true
    local matrix=input.matrix==true
    assert((input.styles==nil or type(input.styles)=='boolean') and (input.palette==nil or type(input.palette)=='boolean')
        and (input.matrix==nil or type(input.matrix)=='boolean') and not (styles and palette)
        and (not matrix or not styles and not palette))
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
        if reopen then counts[2]=counts[2]+1;error('cb_highlight/offline',0) end
        local headers=options.headers or {};local native_ok=options.sensitive==true and options.skip_cookie==true
            and headers.vid==input.owner and headers.accessToken==input.native.accessToken and not headers.Cookie
        if native_ok and options.method=='GET' and options.body==nil and reads[options.url] and counts[0]<80 then
            counts[0]=counts[0]+1;options.persist_response_cookies=false;return request(self,options)
        end
        local operation=({[base..'/book/addBookmark']='create',[base..'/book/removeBookmark']='delete',
            [base..'/book/updateBookmark']=styles and 'style' or palette and 'color' or nil})[options.url]
        if matrix and options.url==base..'/book/updateBookmark' and gate then
            operation=gate:read().phase=='style2' and 'style' or gate:read().phase=='color0' and 'color' or nil
        end
        if native_ok and options.method=='POST' and operation and type(options.body)=='string' and gate then
            assert(tonumber(ffi.C.getpid())~=parent,'highlight write on UI thread')
            local body=self:json_decode(options.body)
            if not gate:claim(operation,body) then counts[3]=counts[3]+1;error('cb_highlight/dry_run',0) end
            counts[1]=counts[1]+1;assert(counts[1]<=((styles or palette or matrix) and 4 or 2));options.persist_response_cookies=false;return request(self,options)
        end
        if web_guard(options,0,function(body) return self:json_decode(body) end)=='read' and counts[0]<80 then
            counts[0]=counts[0]+1;options.persist_response_cookies=false;return request(self,options)
        end
        counts[2]=counts[2]+1;error('cb_highlight/scope',0)
    end
    local settings=Settings:new();local client=Client:new(settings);local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+120
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
            assert(socket.gettime()<deadline,'cb_highlight/timeout') end
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
    local source=assert(Source.capture(book,target,input.source,'web_xhtml'))
    local file=assert(Content.save_book_epub(settings,book,{target},{[input.chapter]=input.source},'fixture-highlight',{},nil,nil,
        Identity.capture(book),{[input.chapter]=source}))
    book.cached_file=file;book.cached_chapters[input.chapter]=file;book.chapters=input.chapters
    assert(Content.save_catalog_cache(client,settings,book,input.chapters));settings:set('books',{[input.book]=book});settings:flush()
    local main=host();assert(main.library_db:putChapters(input.book,input.chapters))
    gate=dofile(fixtures..'native_highlight_trial_gate.lua'):new({permit_writes=input.armed,book_id=input.book,
        original_ids={},create_body=input.body,styles=styles,palette=palette,matrix=matrix},main.library_db,main.client,home)
    main:openChapter(book,target);wait(function() return Reader.instance and Reader.instance.weread end)
    reader=Reader.instance;plugin=reader.weread
    if palette then plugin.settings:set('cloud_highlight_color',3);plugin.settings:flush() end
    if matrix then plugin.settings:set('cloud_highlight_style',0);plugin.settings:set('cloud_highlight_color',3);plugin.settings:flush() end
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local index=assert(require('weread.lib.source_dom').open(reader.document,input.book,input.chapter))
    local first,last=assert(index:locate(input.first)),assert(index:locate(input.last))
    local text=assert(reader.document:getTextFromXPointers(first.xpointer,last.xpointer));reader.document:clearSelection()
    assert(require('weread.lib.source_dom').normalize(text)==require('weread.lib.source_dom').normalize(input.body.markText))
    reader.rolling:onGotoXPointer(first.xpointer);UI:forceRePaint()
    reader.highlight.selected_text={pos0=first.xpointer,pos1=last.xpointer,text=text};reader.highlight:onShowHighlightMenu();UI:forceRePaint()
    assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
    local owner;wait(function() owner=plugin._selection_thought_owner or owner;return owner and (owner.reference or owner.error) end)
    assert(owner.reference,'source selection failed')
    local tr=require('weread.lib.plugin_util').tr
    local function row(label) for _i,item in ipairs(owner.menu.item_table) do if item.text==tr(label) then item.callback();return end end;error('cb_highlight/action',0) end
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
    result.phase='create';row('Save highlight');submit()
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
    require('weread.ui.selection_thought').cancel(plugin);assert(plugin:showMyCloudMarks(input.book));owner=assert(plugin._my_marks_owner)
    local item;for _i,value in ipairs(owner.menu.item_table) do if value.my_note_id==created then item=value end end
    assert(item)
    if styles then
        for step,style in ipairs({0,2}) do
            result.phase='style'..style;item.callback();tap('change_highlight_style')
            UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_style_'..style)):onTapSelectButton()
            submit()
            if synthetic and journal:read().phase=='pending' then
                assert(gate:read().phase=='style'..style..'_pending' and counts[1]==step+1)
                item.callback();tap('change_highlight_style')
                UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_style_'..style)):onTapSelectButton()
                wait(function() return not owner.mark_editor end)
                assert(journal:read().phase=='pending' and counts[1]==step+1 and counts[2]==0)
                result={result='UNCONFIRMED',phase=result.phase,retained_pending=true,no_retry=true};return
            end
            assert(gate:read().phase=='style'..style..'_pending' and journal:read().phase=='idle')
            saved=assert(cache:read(input.book));assert(#saved.updated==1 and saved.updated[1].style==style and saved.updated[1].colorStyle==0)
            acknowledge({seq=step+1,created_id=created});gate:advance_style(created,style)
            item=nil;for _i,value in ipairs(owner.menu.item_table) do if value.my_note_id==created then item=value end end
            assert(item)
        end
    end
    if palette then
        for step,color in ipairs({0,3}) do
            result.phase='color'..color;item.callback();tap('change_highlight_color')
            UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_color_'..color)):onTapSelectButton()
            submit()
            if synthetic and journal:read().phase=='pending' then
                assert(gate:read().phase=='color'..color..'_pending' and counts[1]==step+1)
                item.callback();tap('change_highlight_color')
                UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_color_'..color)):onTapSelectButton()
                wait(function() return not owner.mark_editor end)
                assert(journal:read().phase=='pending' and counts[1]==step+1 and counts[2]==0)
                result={result='UNCONFIRMED',phase=result.phase,retained_pending=true,no_retry=true};return
            end
            assert(gate:read().phase=='color'..color..'_pending' and journal:read().phase=='idle')
            saved=assert(cache:read(input.book));assert(#saved.updated==1 and saved.updated[1].style==1 and saved.updated[1].colorStyle==color)
            acknowledge({seq=step+1,created_id=created});gate:advance_color(created,color)
            item=nil;for _i,value in ipairs(owner.menu.item_table) do if value.my_note_id==created then item=value end end
            assert(item)
        end
    end
    if matrix then
        result.phase='style2';item.callback();tap('change_highlight_style')
        UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_style_2')):onTapSelectButton()
        submit()
        if synthetic and journal:read().phase=='pending' then
            assert(gate:read().phase=='style2_pending' and counts[1]==2)
            item.callback();tap('change_highlight_style')
            UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_style_2')):onTapSelectButton()
            wait(function() return not owner.mark_editor end)
            assert(journal:read().phase=='pending' and counts[1]==2 and counts[2]==0)
            result={result='UNCONFIRMED',phase=result.phase,retained_pending=true,no_retry=true};return
        end
        assert(gate:read().phase=='style2_pending' and journal:read().phase=='idle')
        saved=assert(cache:read(input.book));assert(#saved.updated==1 and saved.updated[1].style==2 and saved.updated[1].colorStyle==3)
        acknowledge({seq=2,created_id=created});gate:advance_style(created,2)
        item=nil;for _i,value in ipairs(owner.menu.item_table) do if value.my_note_id==created then item=value end end;assert(item)
        result.phase='color0';item.callback();tap('change_highlight_color')
        UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_color_0')):onTapSelectButton()
        submit()
        if synthetic and journal:read().phase=='pending' then
            assert(gate:read().phase=='color0_pending' and counts[1]==3)
            item.callback();tap('change_highlight_color')
            UI:forceRePaint();assert(owner.menu._shelf_popup.buttontable:getButtonById('highlight_color_0')):onTapSelectButton()
            wait(function() return not owner.mark_editor end)
            assert(journal:read().phase=='pending' and counts[1]==3 and counts[2]==0)
            result={result='UNCONFIRMED',phase=result.phase,retained_pending=true,no_retry=true};return
        end
        assert(gate:read().phase=='color0_pending' and journal:read().phase=='idle')
        saved=assert(cache:read(input.book));assert(#saved.updated==1 and saved.updated[1].style==2 and saved.updated[1].colorStyle==0)
        acknowledge({seq=3,created_id=created});gate:advance_color(created,0)
        item=nil;for _i,value in ipairs(owner.menu.item_table) do if value.my_note_id==created then item=value end end;assert(item)
    end
    item.callback();result.phase='delete';tap('delete_highlight');submit()
    assert(gate:read().phase=='delete_pending' and journal:read().phase=='idle');acknowledge({seq=(styles or palette or matrix) and 4 or 2,created_id=created})
    saved=assert(cache:read(input.book));assert(#saved.updated==0 and counts[1]==((styles or palette or matrix) and 4 or 2) and counts[2]==0)
    plugin:cancelMyCloudMarks();plugin:onFlushSettings();reader:onClose(false)
    result={result='PASS',native_controls=true,source_verified=true,writes=(styles or palette or matrix) and 4 or 2,denied=0,pending_cleared=true}
end)
if not ok then result.result='UNVERIFIED';result.failure_line=tonumber(type(reason)=='string' and reason:match('cb_fixture_highlight_ui%.lua:(%d+):')) or 0 end
if input and type(input.token)=='string' and input.token:match('^[a-f0-9]+$') and #input.token==32 then
    io.write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_RESULT='..Json.encode(result)..'\n');io.flush()
end
os.exit((result.result=='PASS' or result.result=='DRY_RUN') and 0 or 1)
