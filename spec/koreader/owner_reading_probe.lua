-- Real owner book: plugin selection -> uncached Read -> native EPUB -> offline
-- reopening. Private files are confined to the runner's tmpfs profile. The
-- transport allowlist is installed before the plugin loads and is fail-closed.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local mode=arg[1]
local report={result='UNVERIFIED',phase='init',mode=mode,anonymous_auth=false,transport_guard_selftest=false,
    plugin_selection=false,native_reader=false,source_text_visible=false,source_receipt_verified=false,page_turn=false,position_checkpoint=false,
    local_source_position_verified=false,source_navigation_roundtrip=false,source_dialog_verified=false,legacy_progress_units_preserved=false,
    credential_file_audit=false,workers_reaped=false,shelf_books=0,pages=0,profile_files_audited=0,
    failed_line=0,screenshots=0,last_http_status=0,denied_kind=0,denied_route=0,denied_flags=0,requests={0,0,0,0,0,0,0}}
local counters,plugin,reader,latest_cookies
local descriptors={}
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-reading%-[%w_]+/profile$'))
    local raw=assert(io.stdin:read(256*1024+1));assert(#raw<=256*1024)
    local input=json.decode(raw)
    assert(type(input.vid)=='string' and input.vid:match('^[1-9]%d*$'))
    assert(type(input.book_id)=='string' and input.book_id:match('^[1-9]%d*$'))
    assert(type(input.chapter_uid)=='string' and input.chapter_uid:match('^[1-9]%d*$'))
    assert(type(input.source_text)=='string' and #input.source_text>=32 and #input.source_text<=128)
    assert(input.source_format=='web_xhtml' or input.source_format=='web_txt')
    assert(type(input.source_raw_sha256)=='string' and #input.source_raw_sha256==64 and input.source_raw_sha256:match('^[a-f0-9]+$'))
    assert(type(input.source_sample_offset)=='number' and input.source_sample_offset>=0 and input.source_sample_offset%1==0)
    assert(type(input.cookies)=='table' and input.cookies.wr_vid == input.vid)
    latest_cookies=input.cookies
    local source=home..'/plugins/weread.koplugin'
    package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('color_rendering',false)
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.vid,name=''},cookies=input.cookies,api_key=''}
    local fd=tonumber(ffi.C.memfd_create('weread-reading-probe',1));assert(fd>=0)
    descriptors[#descriptors+1]=fd
    local bytes='return '..require('dump')(auth,nil,true);local offset=0
    while offset<#bytes do
        local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n
    end
    local Settings=require('weread.lib.settings');local new_settings=Settings.new
    function Settings:new()
        local value=new_settings(self);assert(not value.mock_endpoint)
        local flush=value.store.flush
        local secrets={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
        value.store.flush=function(store,...)
            local held={}
            for _i,key in ipairs(secrets) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(secrets) do store.data[key]=held[key] end
            if held.cookies then latest_cookies=held.cookies end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,key=='cookies' and latest_cookies or item) end
        value.settings_file='/proc/self/fd/'..fd
        local sync=value:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0
        value:set('sync',sync)
        local config=value:get('read_report');config.enabled=false;value:set('read_report',config)
        value:flush()
        return value
    end
    report.anonymous_auth=true
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local Protocol=require('weread.lib.protocol')
    local Cookie=require('weread.lib.cookie')
    local root_url=Protocol.reader_url(input.book_id)
    local chapter_url=Protocol.reader_url(input.book_id,input.chapter_uid)
    local progress_urls={}
    for _i,id in ipairs(input.shelf_ids) do progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..id]=true end
    local URL=require('socket.url')
    local function resource(url)
        if type(url)~='string' or #url>8192 or url:find('[%z%c%s]') then return false end
        local parts=URL.parse(url)
        if not parts or parts.scheme~='https' and parts.scheme~='http' or parts.authority~=parts.host
            or parts.fragment or type(parts.host)~='string' then return false end
        local host=parts.host:lower()
        return host:match('%.qpic%.cn$') or host:match('%.qlogo%.cn$') or host:match('%.gtimg%.com$')
            or host:match('%.qq%.com$') and host~='weread.qq.com' and host~='i.weread.qq.com'
    end
    local limits={2,60,8,4,12,60}
    local resource_urls={}
    local function public_redirect(url)
        if type(url)~='string' or #url>8192 or url:find('[%z%c%s]') then return false end
        local parts=URL.parse(url)
        if not parts or parts.scheme~='https' and parts.scheme~='http' or parts.authority~=parts.host
            or parts.fragment or type(parts.host)~='string' then return false end
        local host=parts.host:lower()
        local a,b,c,d=host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
        if a then
            a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
            return a<=255 and b<=255 and c<=255 and d<=255 and a~=0 and a~=10 and a~=127 and a<224
                and not (a==100 and b>=64 and b<=127 or a==169 and b==254 or a==172 and b>=16 and b<=31
                    or a==192 and (b==0 or b==168) or a==198 and (b==18 or b==19 or b==51 and c==100)
                    or a==203 and b==0 and c==113)
        end
        return #host<=253 and host:match('^[a-z%d.-]+%.[a-z][a-z]+$') and not host:match('%.local$')
            and not host:match('%.localhost$') and not host:match('%.internal$')
    end
    local function classify(client,options)
        if mode~='live' then return end
        local h=options.headers or {}
        if h.Authorization or h.authorization or h.accessToken or h.vid then return end
        if resource_urls[options.url] then
            if options.method=='GET' and not options.body and options.skip_cookie==true and not h.Cookie
                and options.persist_response_cookies==false then return 6 end
            return
        end
        local cookies=client.settings:get('cookies',{})
        if cookies.wr_vid~=input.vid then return end
        if h.Cookie and h.Cookie~=Cookie.to_header(cookies) then return end
        if options.skip_cookie and not h.Cookie then return end
        if options.method=='GET' and not options.body then
            if options.url=='https://weread.qq.com/web/shelf/sync' then return 1 end
            if progress_urls[options.url] then return 2 end
            if options.url==root_url or options.url==chapter_url then return 3 end
        elseif options.method=='POST' and type(options.body)=='string' and #options.body<=16384 then
            local decoded,payload=pcall(json.decode,options.body)
            if not decoded or type(payload)~='table' then return end
            if options.url=='https://weread.qq.com/web/book/chapterInfos' then
                local count=0;for _key in pairs(payload) do count=count+1 end
                if payload.bookIds and #payload.bookIds==1 and payload.bookIds[1]==input.book_id
                    and count==1 then return 4 end
            end
            local shard=type(options.url)=='string' and options.url:match('^https://weread%.qq%.com/web/book/chapter/([et]_%d)$')
            if shard and ({e_0=true,e_1=true,e_2=true,e_3=true,t_0=true,t_1=true})[shard] then
                local keys={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
                local count=0;for key in pairs(payload) do if not keys[key] then return end;count=count+1 end
                if count==10 and payload.b==Protocol.e(input.book_id) and payload.c==Protocol.e(input.chapter_uid)
                    and payload.sc==1 and payload.prevChapter==false and payload.st==(shard=='e_2' and 1 or 0)
                    and h.Referer==chapter_url then return 5 end
            end
        end
    end
    local Client=require('weread.lib.client')
    local request,binary,download,follow=Client.request,Client.get_binary,Client.download_to_file,Client.request_follow
    local test={settings={get=function() return input.cookies end}}
    local valid={url=root_url,method='GET',headers={}}
    assert((classify(test,valid)~=nil)==(mode=='live'))
    for _i,url in ipairs({'https://weread.qq.com/web/book/read','https://weread.qq.com/web/login/renewal',
        'https://weread.qq.com/web/shelf/add','https://weread.qq.com/logout',root_url..'?unexpected=1'}) do
        assert(not classify(test,{url=url,method='POST',headers={},body='{}'}))
    end
    assert(not classify(test,{url=root_url,method='GET',headers={Cookie='invalid'}}))
    local params=Protocol.make_content_params(input.book_id,input.chapter_uid,'synthetic-probe-only',{sc=1})
    local content_request={url='https://weread.qq.com/web/book/chapter/e_0',method='POST',
        headers={Referer=chapter_url},body=json.encode(params)}
    assert((classify(test,content_request)~=nil)==(mode=='live'))
    params.c=Protocol.e('999999999999999');content_request.body=json.encode(params)
    assert(not classify(test,content_request))
    assert(not resource('https://127.0.0.1/test') and not resource('https://weread.qq.com/logout'))
    for _i,url in ipairs({'http://127.0.0.1/x','https://10.1.1.1/x','http://192.168.1.1/x',
        'https://user:secret@cdn.qq.com/x','https://cdn.local/x','https://cdn.qq.com/x#fragment'}) do
        assert(not public_redirect(url))
    end
    assert(public_redirect('https://cdn.qq.com/image') and public_redirect('http://101.32.1.1/image'))
    local public_url='https://res.qpic.cn/probe-only'
    resource_urls[public_url]=true
    local public_request={url=public_url,method='GET',skip_cookie=true,persist_response_cookies=false,headers={}}
    assert((classify({settings={get=function() return {} end}},public_request)~=nil)==(mode=='live'))
    public_request.headers.Cookie=Cookie.to_header(input.cookies);assert(not classify(test,public_request))
    resource_urls[public_url]=nil
    report.transport_guard_selftest=true
    function Client:request(options)
        local kind=classify(self,options)
        if not kind or counters[kind-1]>=limits[kind] then
            if counters[6]==0 then
                local url,h=options.url or '',options.headers or {}
                counters[9]=url:find('/web/book/getProgress',1,true) and 1
                    or url:find('/web/book/read',1,true) and 2 or url:find('/web/login/',1,true) and 3
                    or url:find('/web/shelf/',1,true) and 4 or url:find('/web/book/chapter',1,true) and 5
                    or url:find('/web/reader/',1,true) and 6 or resource(url) and 7
                    or url:find('/api/agent/gateway',1,true) and 8 or url:find('/web/book/',1,true) and 9 or 10
                counters[10]=(options.method=='GET' and 1 or 0)+(options.method=='POST' and 2 or 0)
                    +(options.skip_cookie and 4 or 0)+(h.Cookie and 8 or 0)
                    +(h.Cookie==Cookie.to_header(self.settings:get('cookies',{})) and 16 or 0)
                    +(h.Authorization and 32 or 0)+(h.accessToken and 64 or 0)+(options.body and 128 or 0)
                    +(self.settings:get('cookies',{}).wr_vid == input.vid and 256 or 0)
            end
            counters[6]=counters[6]+1;counters[8]=kind or 7;error('reading scope rejected',0)
        end
        counters[kind-1]=counters[kind-1]+1
        local response,code,headers,status=request(self,options)
        counters[7]=tonumber(code) or 0
        return response,code,headers,status
    end
    local function resource_options(url,options)
        assert(resource(url),'resource scope rejected')
        resource_urls[url]=true
        options=options or {};options.skip_cookie=true;options.persist_response_cookies=false;options.sensitive=true
        return options
    end
    function Client:get_binary(url,options)
        return binary(self,url,resource_options(url,options))
    end
    function Client:download_to_file(url,path,options)
        return download(self,url,path,resource_options(url,options))
    end
    function Client:request_follow(options,...)
        -- download_to_file installs its own reset callback. Compose the guard
        -- here so streamed image/archive redirects keep that production reset.
        if resource_urls[options.url] then
            local redirected=options.on_redirect
            options.on_redirect=function(previous,next_url,...)
                assert(resource_urls[previous] and public_redirect(next_url),'resource redirect rejected')
                resource_urls[next_url]=true
                if redirected then redirected(previous,next_url,...) end
            end
        end
        return follow(self,options,...)
    end
    local Common=require('weread.ui.common')
    Common.isNetworkOnline,Common.isNetworkConnected=function() return mode=='live' end,function() return mode=='live' end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    package.path=source..'/?.lua;'..package.path
    local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
    local socket=require('socket')
    local function tick() UI:setInputTimeout(0);UI:handleInput() end
    local function pump(predicate)
        local deadline=socket.gettime()+70
        while not predicate() do assert(socket.gettime()<deadline);tick();socket.sleep(.01) end
    end
    FM:showFiles(home);plugin=assert(FM.instance.weread)
    local host=plugin
    report.phase='shelf'
    if mode=='live' then
        local loaded=false
        plugin:refreshBookshelf(nil,{on_loaded=function(success) loaded=success end})
        pump(function() return not plugin.shelf_refreshing end)
        assert(loaded and plugin.shelf_active_source=='web')
    end
    local books=assert(plugin.library_db:getShelf());assert(#books==input.shelf_books)
    report.shelf_books=#books
    local target
    for _i,book in ipairs(books) do if tostring(book.bookId)==input.book_id then target=book end end
    assert(target)
    plugin:showHome()
    -- The source sample need not be in the six most recent Home rows; use the
    -- normal shelf selection callback with the actual file-backed shelf row.
    plugin:closeWeReadUI();plugin:showBookshelf()
    local view=assert(plugin.shelf_view);assert(type(view.on_select)=='function')
    local index
    for position,book in ipairs(view.books) do if tostring(book.bookId)==input.book_id then index=position end end
    assert(index and view.paged)
    local page=math.floor((index-1)/view.page_size)+1
    if page~=view.page then plugin:showShelfView('books',nil,nil,{page=page});view=assert(plugin.shelf_view) end
    local visible
    for _i,book in ipairs(view:getVisibleBooks()) do if tostring(book.bookId)==input.book_id then visible=book end end
    assert(visible);UI:forceRePaint();target=visible
    view.on_select(target,'books');report.plugin_selection=true
    report.phase='detail'
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    local detail=assert(plugin._book_detail_view)
    local label=require('weread.lib.plugin_util').tr('▤ Read')
    local pressed=false
    for _i,buttons in ipairs({detail._action_buttons or {},detail._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do
            if button.text==label then assert(button.enabled~=false);button.callback();pressed=true;break end
        end
        if pressed then break end
    end
    assert(pressed)
    if mode=='live' then assert(plugin.book_reading_context and not Reader.instance) end
    report.phase='prepare'
    pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document end)
    reader=Reader.instance;plugin=reader.weread
    report.phase='native'
    local document=reader.document
    assert(document.file:sub(1,#home)==home and document.file:match('%.epub$'))
    assert(plugin:detectWeReadBook()==input.book_id)
    local book=assert(plugin.settings:get_book(input.book_id))
    assert(book.cached_chapters and book.cached_chapters[input.chapter_uid]==document.file)
    local source_receipt=assert(require('weread.lib.position_source').read_document(document,input.book_id,input.chapter_uid))
    assert(source_receipt.format==input.source_format and source_receipt.raw_sha256==input.source_raw_sha256)
    report.source_receipt_verified=true
    report.pages=document:getPageCount();assert(report.pages>1)
    local matches=assert(document:findAllText(input.source_text,false,0,4,false,0))
    assert(matches[1] and matches[1].start)
    local source_index,source_reason=require('weread.lib.source_dom').open(document,input.book_id,input.chapter_uid)
    assert(source_index,source_reason)
    local source_match,match_reason=source_index:capture(matches[1].start)
    assert(source_match,match_reason)
    assert(source_match.co==input.source_sample_offset)
    report.native_reader=true
    local checkpoint_path=home..'/checkpoint.json'
    if mode=='reopen' then
        local file=assert(io.open(checkpoint_path,'rb'));local checkpoint=json.decode(file:read('*a'));file:close()
        assert(checkpoint.file==document.file and document:isXPointerInCurrentPage(checkpoint.xpointer))
        assert(reader:getCurrentPage()==checkpoint.page)
    end
    local origin=document:getXPointer()
    reader.rolling:onGotoXPointer(matches[1].start);tick()
    assert(document:isXPointerInCurrentPage(matches[1].start))
    local y,x=document:getScreenPositionFromXPointer(matches[1].start)
    assert(y>=0 and y<Device.screen:getHeight() and x>=0 and x<Device.screen:getWidth())
    UI:forceRePaint();report.source_text_visible=true
    reader.rolling:onGotoXPointer(origin);tick()
    local next_page=reader:getCurrentPage()==1 and 2 or 1
    reader.rolling:onGotoPage(next_page);tick()
    assert(reader:getCurrentPage()==next_page)
    report.page_turn=true
    UI:forceRePaint()
    -- Read an ordinary body page through the production cooperative service,
    -- independent archive worker, position dialog and bound native navigator.
    reader.rolling:onGotoPage(math.min(3,report.pages));tick()
    local service=assert(plugin.source_position)
    pump(function() return service:current()~=nil end)
    local position=assert(service:current())
    local basis=require('weread.lib.position_source').coordinate_basis(input.source_format)
    assert(position.basis==basis and position.upload_verified==false and position.raw_sha256==input.source_raw_sha256)
    local location=assert(require('weread.lib.source_context').location(document,reader.view.view_mode))
    local current,current_reason=source_index:capture(location.xpointer)
    assert(current,current_reason);assert(current.co==position.chapter_offset)
    report.local_source_position_verified=true
    plugin:showReadingPosition()
    pump(function() return plugin._source_position_message~=nil end)
    assert(plugin._source_position_message.text:find('已定位到当前页正文',1,true)
        and plugin._source_position_message.text:find('精确云端同步仍在验证中',1,true))
    UI:forceRePaint();plugin:closeReadingPositionMessage();report.source_dialog_verified=true
    local legacy=assert(plugin.progress_sync:capture_local())
    local applied
    assert(plugin:openSourcePosition(position,function(result) applied=result or false end))
    pump(function() return applied~=nil end)
    assert(applied and applied.basis==basis and applied.chapter_offset==position.chapter_offset)
    local retained=assert(plugin.progress_sync:current_source_target())
    assert(retained.basis==basis and retained.chapter_offset==position.chapter_offset and retained.upload_verified==false)
    local roundtrip=assert(source_index:capture(document:getXPointer()))
    assert(roundtrip.co==position.chapter_offset)
    report.source_navigation_roundtrip=true
    local after=assert(plugin.progress_sync:capture_local())
    assert(after.chapter_offset==legacy.chapter_offset and after.source_position.basis==basis
        and after.source_position.chapter_offset==position.chapter_offset and after.chapter_offset~=position.chapter_offset)
    report.legacy_progress_units_preserved=true
    local checkpoint={file=document.file,xpointer=document:getXPointer(),page=reader:getCurrentPage()}
    local file=assert(io.open(checkpoint_path,'wb'));assert(file:write(json.encode(checkpoint)));file:close()
    report.phase='close'
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    plugin:closeWeReadUI();plugin:onFlushSettings();reader:onClose(false);reader=nil
    plugin.settings:flush();G_reader_settings:flush();report.position_checkpoint=true
    pump(function() return not plugin.shelf_cover_job and not plugin.shelf_cover_pending
        and not plugin.book_reading_context and not plugin.downloader._active_job
        and not host.shelf_cover_job and not host.shelf_cover_pending
        and not host.book_reading_context and not host.downloader._active_job end)
    local status=ffi.new('int[1]')
    pump(function()
        local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
        -- Reap all completed direct workers; zero still means a live child.
        while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end
        -- Linux ECHILD is 10 (posix_h exposes waitpid but no errno constants).
        return child<0 and ffi.errno()==10
    end)
    report.workers_reaped=true
    report.phase='audit'
    local lfs=require('libs/libkoreader-lfs')
    local secrets={}
    for key,value in pairs(latest_cookies) do if key~='wr_vid' and #value>=8 then secrets[#secrets+1]=value end end
    for key,value in pairs(input.cookies) do if key~='wr_vid' and #value>=8 then secrets[#secrets+1]=value end end
    local function audit(path)
        for entry in lfs.dir(path) do
            if entry~='.' and entry~='..' and not (path==home and entry=='plugins') then
                local filename=path..'/'..entry;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename)
                elseif info.mode=='file' then
                    report.profile_files_audited=report.profile_files_audited+1
                    assert(report.profile_files_audited<=1024 and info.size<=16*1024*1024)
                    local handle=assert(io.open(filename,'rb'));local content=handle:read('*a');handle:close()
                    for _i,secret in ipairs(secrets) do assert(not content:find(secret,1,true)) end
                else error('unexpected profile entry',0) end
            end
        end
    end
    audit(home);report.credential_file_audit=true
    assert(counters[6]==0)
    report.phase,report.result='complete','PASS'
end)
if counters then
    for index=1,7 do report.requests[index]=tonumber(counters[index-1]) end
    report.last_http_status,report.denied_kind=tonumber(counters[7]),tonumber(counters[8])
    report.denied_route,report.denied_flags=tonumber(counters[9]),tonumber(counters[10])
    ffi.C.munmap(counters,4096)
end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then
    report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_reading_probe%.lua:(%d+):')) or 0
end
io.stdout:write('\nWEREAD_OWNER_READING_RESULT='..json.encode{report=report,cookies=latest_cookies or {}}..'\n')
os.exit(ok and 0 or 1)
