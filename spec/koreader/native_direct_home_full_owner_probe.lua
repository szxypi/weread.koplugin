-- Real plugin details -> native catalog -> ReaderUI; private data stays in tmpfs.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local live_cloud=input.live_cloud_resume==true
if live_cloud then
    assert(not input.mock_endpoint and input.read_entry=='shelf')
    if input.exact_resume then
        assert(not input.start_unread and type(input.cloud_excerpt)=='string'
            and #input.cloud_excerpt>=12 and #input.cloud_excerpt<=512)
    else
        assert(input.start_unread==true and input.cloud_chapter_uid=='0' and not input.cloud_excerpt)
    end
end
if input.missing_resume_source then assert(live_cloud and input.exact_resume) end
local Settings=require('weread.lib.settings');local settings=Settings:new()
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{})
local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
local cache=settings:get('cache');cache.show_annotations=false;cache.auto_prefetch_next_chapter=false
cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local Common=require('weread.ui.common')
Common.isNetworkOnline=function() return input.offline~=true end;Common.isNetworkConnected=Common.isNetworkOnline
local function diagnostic(name,value)
    local file=assert(io.open(home..'/native-home-'..name,'wb'));assert(file:write(value));assert(file:close())
end
local Archive=require('weread.lib.native_chapter_archive');local archive_read=Archive.read
Archive.read=function(...)
    local ok,value=pcall(archive_read,...)
    if not ok then
        local reasons={['E-Ink ZIP 文件名无效']='filename',['E-Ink ZIP 条目超限或不支持']='entry_limit',
            ['E-Ink ZIP 密码校验失败']='password',['E-Ink ZIP 内容校验失败']='checksum',
            ['E-Ink 章节清单未返回当前章节']='manifest_chapter',['E-Ink 未返回唯一章节正文']='body_selection',
            ['E-Ink 章节清单无法解析']='manifest_parse',['E-Ink 章节清单正文为空或超限']='body_limit'}
        local code='other'
        if type(value)=='string' then for pattern,reason in pairs(reasons) do
            if value:find(pattern,1,true) then code=reason;break end
        end end
        diagnostic('archive',code);error('archive verification failed',0)
    end
    diagnostic('archive','ok')
    return value
end
local Client=require('weread.lib.client');local previous=Client.request
Client.request=function(self,options)
    local count=assert(io.open(home..'/request-count','ab'));assert(count:write('1'));assert(count:close())
    assert(input.offline~=true,'offline shelf reading used the network')
    local url,headers=options.url,options.headers or {};local base='https://i.weread.qq.com'
    local query=input.store_search_keyword and require('weread.lib.protocol').sorted_query{
        keyword=input.store_search_keyword,scope=10,count=20,maxIdx=0}
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    if query and url==base..'/store/search?'..query then assert(options.method=='GET')
    elseif url==base..'/book/info?bookId='..input.book_id then assert(options.method=='GET')
    elseif input.cloud_chapter_uid and url==base..'/book/getProgress?bookId='..input.book_id then
        assert((live_cloud or input.mock_endpoint and os.getenv('WEREAD_SYNTHETIC')=='1') and options.method=='GET')
        assert(self.settings.mock_endpoint==input.mock_endpoint)
        local cloud=assert(io.open(home..'/cloud-count','ab'));assert(cloud:write('1'));assert(cloud:close())
    elseif url==base..'/book/chapterInfos' then
        local body=json.decode(options.body)
        assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
            and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
    elseif url:find(base..'/book/chapterdownload?',1,true)==1 then
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
            and url:find('chapters=0%2C'..input.uid..'&',1,true)
            and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
        if input.missing_resume_source then
            local chapter=assert(io.open(home..'/chapter-count','ab'));assert(chapter:write('1'));assert(chapter:close())
        end
    else
        assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
            and not headers.vid and not headers.accessToken and not headers.Cookie)
    end
    if url:find(base,1,true)==1 then
        assert(headers.vid==input.credentials.vid and headers.accessToken==input.credentials.accessToken)
    end
    local bytes,first=0,''
    if options.diagnostic_api=='native_chapter_download' and type(options.sink)=='function' then
        local sink=options.sink
        options.sink=function(chunk,...)
            if type(chunk)=='string' then
                bytes=bytes+#chunk
                if #first<4 then first=(first..chunk):sub(1,4) end
            end
            return sink(chunk,...)
        end
    end
    local ok,a,b,c=pcall(previous,self,options)
    if options.diagnostic_api=='native_chapter_download' then
        local status=ok and tonumber(b)
        diagnostic('download',status==200 and 'http_200' or status==401 and 'http_401'
            or status==429 and 'http_429' or ok and 'http_other' or 'transport')
        local kind=bytes==0 and 'empty' or first:sub(1,2)=='PK' and 'zip'
            or first:match('^%s*{') and 'json' or 'other'
        local keys=0
        if type(c)=='table' then for key in pairs(c) do
            if type(key)=='string' and key:lower()=='encryptkey' then keys=keys+1 end
        end end
        diagnostic('payload',kind..(keys==1 and '_key' or keys==0 and '_nokey' or '_duplicate'))
    end
    if not ok then error('guarded request failed',0) end
    return a,b,c
end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket')
local FM=require('apps/filemanager/filemanager');local Reader=require('apps/reader/readerui')
local stage='setup'
local function pump(fn)
    local deadline=socket.gettime()+(input.mock_endpoint and 25 or 90)
    while not fn() do
        if socket.gettime()>=deadline then print('WEREAD_DIRECT_HOME_STAGE='..stage);error('full native home timeout') end
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
FM:showFiles(home);local host=assert(FM.instance.weread)
host.settings.mock_endpoint=input.mock_endpoint
local failure,ui_failed,resume_message,cloud_xpointer
local direct=input.exact_resume or input.start_unread
if direct then
    assert(live_cloud or input.mock_endpoint and os.getenv('WEREAD_SYNTHETIC')=='1')
    host.showInfo=function() ui_failed=true end
    local show_list=host.showList
    host.showList=function(self,title,...)
        assert(title~=require('weread.lib.plugin_util').tr('E-Ink chapters'),
            'direct continuation opened a chapter selector')
        return show_list(self,title,...)
    end
end
if input.exact_resume then
    local CloudOpen=require('weread.ui.native_direct_cloud_open');local receive=CloudOpen.receive
    CloudOpen.receive=function(next_host,...)
        if input.missing_resume_source then
            local path=assert(next_host.ui.document.file)
            assert(path:sub(1,#home+1)==home..'/' and require('weread.lib.native_direct_path').contains(next_host.settings,path))
            assert(os.remove(assert(path:match('^(.*)/[^/]+$'))..'/native-source.txt'))
        end
        next_host.settings.mock_endpoint=input.mock_endpoint
        next_host.showInfo=function(_,message) resume_message=message end
        return receive(next_host,...)
    end
    local geometry=require('weread.lib.reader_position');local goto_xpointer=geometry.goto_xpointer
    geometry.goto_xpointer=function(reader,point)
        cloud_xpointer=point
        return goto_xpointer(reader,point)
    end
end
local shelf_owner
if input.read_entry then
    assert((live_cloud or os.getenv('WEREAD_SYNTHETIC')=='1') and not next(host.settings:get('cookies',{})))
    host.qr_login.start=function() error('native-only reading tried to start Web login') end
    if input.cloud_chapter_uid then G_reader_settings:saveSetting('items_per_page',1) end
end
if input.read_entry=='shelf' then
    local shelf_settings=host.settings:get('shelf')
    shelf_settings.tap_to_read=true;host.settings:set('shelf',shelf_settings);host.settings:flush()
    host:applyShelfSnapshot({{bookId=input.book_id,title='Synthetic book',author='Fixture'}},{})
    if input.require_cached then
        local book=host.settings:get_book(input.book_id)
        assert(host:nativeChapterCachePresent(input.book_id) and not (book and book.native_home_resume),
            'partial-download fixture already has a resume record or is missing its saved chapter')
    end
    host:showShelfView('books',nil,nil,{skip_cover_fetch_once=true,skip_progress_fetch_once=true})
    shelf_owner=assert(host.shelf_view)
    local row=assert(shelf_owner._item_rows[1]);assert(tostring(row.book.bookId)==input.book_id)
    UI:forceRePaint()
    local pos=require('ui/geometry'):new{x=row.dimen.x+math.floor(row.dimen.w/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
    assert(row:handleEvent(require('ui/event'):new('Gesture',{ges='tap',pos=pos})))
elseif input.store_search_keyword then
    host.fetchVisibleShelfCovers=function() end
    if input.quick_search then
        local entry
        for _,item in ipairs(host:getMainMenuItems()) do
            if item.text==require('weread.lib.plugin_util').tr('Search') then entry=item end
        end
        assert(entry and type(entry.callback)=='function');entry.callback()
    else
        host:showBookstore()
        local search
        for _,item in ipairs(host.shelf_view._action_buttons or {}) do
            if item.text==require('weread.lib.plugin_util').tr('Search WeRead') then search=item end
        end
        assert(search);search.callback()
    end
    stage='search_dialog';pump(function() local top=UI:getTopmostVisibleWidget();return top and type(top.setInputText)=='function' end)
    local dialog=UI:getTopmostVisibleWidget();dialog:setInputText(input.store_search_keyword);dialog.buttons[1][2].callback()
    stage='search_results';pump(function() return not host.discovery_loading and host.discovery_state and host.discovery_state.kind=='search' end)
    assert(host.discovery_state.source_kind=='native')
    local page=assert(host.shelf_view);local position
    for i,row in ipairs(page.books) do if tostring(row.bookId)==input.book_id then assert(not position);position=i end end
    assert(position and page.paged)
    local target_page=math.floor((position-1)/page.page_size)+1
    if target_page~=page.page then page.on_page_changed(target_page);page=assert(host.shelf_view) end
    local selected
    for _,row in ipairs(page:getVisibleBooks()) do if tostring(row.bookId)==input.book_id then selected=row end end
    assert(selected);page.on_select(selected,'books')
    stage='details';pump(function() return host._book_detail_view~=nil end)
else
    host:showBookRecord({book_id=input.book_id,title='Synthetic book',author='Fixture'},{verified_metadata=true})
end
if not shelf_owner then
    local view=assert(host._book_detail_view);local button
    local actions=input.read_entry and view._footer_actions or view._action_buttons
    local text=require('weread.lib.plugin_util').tr(input.read_entry=='catalog' and '☷ Chapter list'
        or input.read_entry=='details' and '▤ Read' or 'Read E-Ink chapter')
    for _,item in ipairs(actions) do if item.text==text then button=item end end
    assert(button and button.enabled~=false)
    if input.read_entry then UI:forceRePaint();button:onTapFooterAction()
    else button.callback() end
end
local function choose_chapter()
    stage='catalog';pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
    local ctx=assert(host._native_direct_reading);local index
    if shelf_owner then
        assert(ctx.shelf_owner==shelf_owner and not host._book_detail_view,'shelf tap opened details')
        require('weread.ui.shelf_popup').redrawForMetadata(host,shelf_owner,function()
            error('shelf refresh replaced the native chapter selector')
        end)
    end
    if input.offline then
        assert(ctx.offline and not ctx.catalog and #ctx.menu.item_table==1,'offline shelf did not list the saved chapter')
        index=1
    else
        for i,row in ipairs(ctx.catalog.chapters) do if row.chapterUid==input.uid then assert(not index and row.downloadable);index=i end end
    end
    assert(index and ctx.menu.item_table[index].select_enabled)
    if input.cloud_chapter_uid then
        local prefix=require('weread.lib.plugin_util').tr('Cloud reading chapter')..' · '
        assert(input.uid==input.cloud_chapter_uid and (live_cloud or index==2) and ctx.menu.page==ctx.menu:getPageNumber(index)
            and ctx.menu.item_table[index].text:find(prefix,1,true)==1,'the catalog did not locate the cloud chapter')
    end
    local worker=assert(host._native_direct_worker);local worker_start=worker.start
    worker.start=function(self,task,callback,...)
        return worker_start(self,task,function(value)
            local allowed={not_entitled=true,auth_expired=true,rate_limited=true,service_rejected=true,session_changed=true,
                catalog_changed=true,unavailable=true,invalid_source=true,invalid_image=true,remote_unsupported=true,storage=true}
            if type(value)=='table' and allowed[value.error] then failure=value.error end
            local resources={missing=true,unsupported=true,ambiguous=true,inline_style=true,css=true,css_import=true,css_url=true,
                html=true,body=true,link_tag=true,style_tag=true,unsupported_markup=true,background_attribute=true,
                other_source_attribute=true,multiple_styles=true,source=true,source_changed=true,asset=true,assets=true,
                remote_limit=true,missing_limit=true,options=true,unavailable=true}
            local resource=type(value)=='table' and type(value.error)=='string' and value.error:match('^native_resources/([a-z_]+)$')
            if resource and resources[resource] then failure='resource_'..resource end
            return callback(value)
        end,...)
    end
    host.showInfo=function() ui_failed=true end
    ctx.menu:onMenuSelect(ctx.menu.item_table[index])
end
if not direct then choose_chapter() end
stage='reader';pump(function() return ui_failed or Reader.instance and Reader.instance.weread and Reader.instance.document end)
if ui_failed then print('WEREAD_DIRECT_HOME_REASON='..(failure or 'unavailable'));error('chapter preparation failed') end
local reader=Reader.instance;local path=reader.document.file
assert(require('weread.lib.native_direct_path').contains(reader.weread.settings,path))
if input.start_unread then
    assert(reader.document:getCurrentPage()==1,'unread book did not open at its first page')
end
if input.exact_resume then
    stage='cloud_position';pump(function()
        return resume_message~=nil or cloud_xpointer and not reader.weread._native_direct_cloud_open
    end)
    assert(not resume_message,resume_message)
    local doc=reader.document
    assert(cloud_xpointer and doc:isXPointerInCurrentPage(cloud_xpointer))
    local normalize=require('weread.lib.source_dom').normalize
    local quote=assert(normalize(input.cloud_excerpt or 'Chapter '..input.uid..', synthetic paragraph 70'))
    local last=cloud_xpointer
    for _i=1,#quote*2 do
        local following=doc:getNextVisibleChar(last)
        if not following or following==last then break end
        last=following
    end
    assert(assert(normalize(doc:getTextFromXPointers(cloud_xpointer,last))):sub(1,#quote)==quote,
        'the reader did not open at the original cloud text')
end
if input.store_search_keyword then
    local css=assert(reader.document:getDocumentFileContent('OEBPS/style.css'))
    assert(type(input.inline_style)=='string' and #input.inline_style>0 and css:find(input.inline_style,1,true),
        'inline stylesheet not present in rendered EPUB')
end
stage='home_record';pump(function() local book=reader.weread.settings:get_book(input.book_id)
    return book and book.native_home_resume and book.native_home_resume.entry end)
local entry=reader.weread.settings:get_book(input.book_id).native_home_resume.entry
assert(entry.book_id==input.book_id and entry.chapter_uid==input.uid and entry.book_version==input.book_version
    and entry.source_sha256==input.source_sha256 and not reader.weread:detectWeReadBook())
local anchor
if live_cloud then
    anchor=assert(reader.document:getXPointer())
else
    if reader.document:getPageCount()<2 then assert(reader.font:onSetFontSize(48));UI:forceRePaint() end
    assert(reader.document:getPageCount()>=2)
    local first=assert(reader.document:getXPointer());reader.rolling:onGotoPage(2);UI:forceRePaint()
    anchor=assert(reader.document:getXPointer());assert(anchor~=first)
end
if input.quick_search then
    local active=reader.weread;active.settings.mock_endpoint=input.mock_endpoint
    assert(active.settings:get('api_key','')=='' and not next(active.settings:get('cookies',{})),
        'quick search fixture unexpectedly contains a gateway key or Web cookies')
    active.fetchVisibleShelfCovers=function() end
    assert(active:onShowWeReadQuickMenu())
    local quick_button
    stage='quick_menu';pump(function()
        local top=UI:getTopmostVisibleWidget()
        if top and type(top.buttons)=='table' then
            for _,row in ipairs(top.buttons) do for _,item in ipairs(row) do
                if item.text==require('weread.lib.plugin_util').tr('Search bookstore') then quick_button=item end
            end end
        end
        return quick_button~=nil
    end)
    assert(quick_button.enabled~=false);quick_button.callback()
    stage='quick_input';pump(function() return active.shelf_view and active.shelf_view._shelf_popup end)
    local input_dialog=active.shelf_view._shelf_popup
    assert(type(input_dialog.setInputText)=='function');input_dialog:setInputText(input.store_search_keyword)
    input_dialog.buttons[1][2].callback()
    stage='quick_results';pump(function() return not active.discovery_loading and active.discovery_state
        and active.discovery_state.kind=='search' end)
    assert(active.discovery_state.source_kind=='native' and active.discovery_state.keyword==input.store_search_keyword)
    local found=false
    for _,book in ipairs(active.discovery_state.books) do if tostring(book.bookId)==input.book_id then found=true end end
    assert(found,'quick search did not return the selected book')
    active:closeWeReadUI();UI:forceRePaint()
    assert(Reader.instance==reader and reader.document.file==path and reader.document:isXPointerInCurrentPage(anchor),
        'closing bookstore search changed the open reading page')
end
local file=assert(io.open(home..'/anchor','wb'));assert(file:write(anchor));assert(file:close())
while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
reader.weread:onFlushSettings();reader:onClose(false);assert(not Reader.instance)
local function count_reads(name)
    local stream=io.open(home..'/'..name,'rb')
    if not stream then return end
    local reads=#assert(stream:read('*a'));assert(stream:close());return reads
end
local requests=count_reads('request-count') or 0
assert(input.offline~=true or requests==0)
print('WEREAD_DIRECT_HOME_FULL='..json.encode{ok=true,path=path,requests=requests,source_matches=true,
    store_search=input.store_search_keyword~=nil,quick_search=input.quick_search==true,
    cloud_position_verified=input.exact_resume==true,first_page_verified=input.start_unread==true,
    cloud_reads=count_reads('cloud-count'),chapter_reads=count_reads('chapter-count')})
