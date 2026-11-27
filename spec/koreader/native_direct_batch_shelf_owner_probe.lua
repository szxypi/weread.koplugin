-- Full PluginLoader/FileManager shelf -> details -> batch, in tmpfs only.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=assert(arg[1]);package.path=plugin..'/?.lua;'..package.path
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local vid=assert(input.vid or input.credentials and input.credentials.vid)
local sources=assert(input.sources);local book_id=assert(input.book_id)
local count=0;for _ in pairs(sources) do count=count+1 end
assert(count>=1 and count<=8 and input.total>=count and input.total<=200)
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local settings=require('weread.lib.settings'):new()
if input.mode=='online' then
    settings:set('account',{user_vid=vid,name='Verification',login_method='qr'});settings:set('cookies',{})
    local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
    local cache=settings:get('cache');cache.show_annotations=false;cache.auto_prefetch_next_chapter=false
    cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
    local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
end
local Common=require('weread.ui.common')
Common.isNetworkOnline=function() return input.mode~='offline' end;Common.isNetworkConnected=Common.isNetworkOnline
if input.mode=='offline' then
    assert(dofile(assert(arg[3])..'/spec/koreader/offline_network_guard.lua')())
else
    assert(input.credentials and input.credentials.vid==vid)
    local store={read=function() return input.credentials,1,nil,false end}
    local Access=require('weread.lib.native_read_access');local original=Access.capture
    Access.capture=function(s,existing) return original(s,existing or store) end
    local Client=require('weread.lib.client');local request=Client.request;local requested={}
    Client.request=function(self,options)
        local url,headers=options.url,options.headers or {};local base='https://i.weread.qq.com'
        assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        if url==base..'/book/info?bookId='..book_id then assert(options.method=='GET')
        elseif url==base..'/book/chapterInfos' then
            assert(options.method=='POST');local body=json.decode(options.body)
            assert(#body.bookIds==1 and body.bookIds[1]==book_id and body.synckeys[1]==0
                and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
        elseif url:find(base..'/book/chapterdownload?',1,true)==1 then
            local uid=url:match('[?&]chapters=0%%2C([1-9]%d*)&')
            assert(input.mode=='online' and options.method=='GET' and url:find('bookId='..book_id..'&',1,true)
                and uid and sources[uid] and not requested[uid]
                and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
            requested[uid]=true
        else
            assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
                and not headers.vid and not headers.accessToken and not headers.Cookie)
        end
        if url:find(base,1,true)==1 then assert(headers.vid==vid and headers.accessToken==input.credentials.accessToken) end
        local ledger=home..'/request-count';local previous=io.open(ledger,'rb');local n=0
        if previous then n=#assert(previous:read('*a'));assert(previous:close()) end
        assert(n<200);local file=assert(io.open(ledger,'ab'));assert(file:write('1'));assert(file:close())
        return request(self,options)
    end
end
local result,host
local Worker=require('weread.lib.memory_worker');local start=Worker.start
Worker.start=function(self,task,callback,progress)
    return start(self,task,function(value)
        if host and host._native_direct_reading and host._native_direct_reading.phase=='batch' then result=value end
        callback(value)
    end,progress)
end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket')
local function pump(predicate)
    local deadline=socket.gettime()+300
    while not predicate() do
        assert(socket.gettime()<deadline,'owner shelf batch timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local FM=require('apps/filemanager/filemanager');local Reader=require('apps/reader/readerui')
FM:showFiles(home);host=assert(FM.instance.weread);host.settings.mock_endpoint=input.mock_endpoint
host.fetchVisibleShelfCovers=function() end;host.prepareShelfProgress=function() return nil end
if input.mode=='online' then assert(host.library_db:cacheShelf(input.shelf_books,{})) end
host:showBookshelf()
local shelf=assert(host.shelf_view);assert(#shelf.books==#input.shelf_books)
local position
for index,book in ipairs(shelf.books) do if tostring(book.bookId or book.book_id)==book_id then assert(not position);position=index end end
assert(position and shelf.paged)
local page=math.floor((position-1)/shelf.page_size)+1
if page~=shelf.page then shelf.on_page_changed(page);shelf=assert(host.shelf_view) end
local target
for _,book in ipairs(shelf:getVisibleBooks()) do if tostring(book.bookId or book.book_id)==book_id then target=book end end
assert(target)
if input.mode~='online' then assert(host:isBookDownloaded(target),'saved native chapters missing downloaded status') end
shelf.on_select(target,'books')
pump(function() return host._book_detail_view~=nil end)
local detail=assert(host._book_detail_view);local action
if input.mode~='online' then
    assert(detail.data.status_line:find(require('weread.lib.plugin_util').tr('E-Ink chapters saved'),1,true),
        'saved native chapter status missing from details')
end
local label=input.mode=='offline' and 'Read saved E-Ink chapter' or 'Download E-Ink chapters'
for _,button in ipairs(detail._action_buttons) do
    if button.text==require('weread.lib.plugin_util').tr(label) then action=button end
end
assert(action);action.callback()
local Cache=require('weread.lib.native_direct_cache')
if input.mode=='offline' then
    pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
    local ctx=assert(host._native_direct_reading);local menu=assert(ctx.menu)
    local entries=assert(Cache.list(host.settings,vid,book_id,function() return true end))
    assert(#menu.item_table==count and #entries==count)
    local selected=1
    for index,entry in ipairs(entries) do
        if sources[entry.chapter_uid] and sources[entry.chapter_uid].token then selected=index;break end
    end
    menu:onMenuSelect(menu.item_table[selected])
    pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document end)
    local reader=Reader.instance;local entry=assert(Cache.identify(reader.weread.settings,vid,reader.document.file,function() return true end))
    assert(sources[entry.chapter_uid] and entry.source_sha256==sources[entry.chapter_uid].sha256)
    assert(reader.document:getPageCount()>0)
    local matched=0
    if sources[entry.chapter_uid].token then
        local hits=assert(reader.document:findAllText(sources[entry.chapter_uid].token,false,0,8,false,0));assert(hits[1])
        matched=1
    end
    local rows=assert(Cache.list(reader.weread.settings,vid,book_id,function() return true end));assert(#rows==count)
    for _,row in ipairs(rows) do
        assert(sources[row.chapter_uid] and row.source_sha256==sources[row.chapter_uid].sha256)
        assert(Cache.open(reader.weread.settings,vid,book_id,row,function() return true end))
    end
    print('WEREAD_BATCH_SHELF='..json.encode{ok=true,mode='offline',chapters=count,network_blocked=true,
        full_plugin=true,shelf_count=#input.shelf_books,reader_opened=true,tokens=matched})
    return
end
host.showInfo=function(self) self.completed=true end
pump(function() return host.completed or host._native_direct_reading and host._native_direct_reading.confirm end)
if host.completed then print('WEREAD_BATCH_SHELF='..json.encode{ok=false,phase='catalog'});return end
local ctx=assert(host._native_direct_reading);assert(ctx.catalog.version==input.version and #ctx.catalog.chapters==input.total)
local readable=0
for _,row in ipairs(ctx.catalog.chapters) do if row.downloadable then assert(sources[row.chapterUid]);readable=readable+1 end end
assert(readable==count)
local confirm=assert(ctx.confirm);confirm.choice2_callback();UI:close(confirm)
pump(function() return host.completed end)
if type(result)~='table' or result.ok~=true then
    local allowed={auth_expired=true,rate_limited=true,session_changed=true,catalog_changed=true,
        unavailable=true,not_entitled=true,storage=true,invalid_source=true,invalid=true}
    print('WEREAD_BATCH_SHELF='..json.encode{ok=false,phase='download',reason=allowed[result and result.error] and result.error or 'other'});return
end
assert(result.downloaded==(input.mode=='online' and count or 0)
    and result.saved==(input.mode=='repeat' and count or 0) and result.unavailable==input.total-count)
local rows=assert(Cache.list(host.settings,vid,book_id,function() return true end));assert(#rows==count)
local missing=0
for _,entry in ipairs(rows) do
    assert(sources[entry.chapter_uid] and entry.book_version==input.version
        and entry.source_sha256==sources[entry.chapter_uid].sha256)
    assert(Cache.open(host.settings,vid,book_id,entry,function() return true end))
    if entry.missing_images>0 then missing=missing+1 end
end
assert(missing==result.missing and not host._native_direct_reading and not host.busy_message)
assert(host:isBookDownloaded(target),'completed native batch missing downloaded status')
local shelf_settings=host.settings:get('shelf');local previous_filter=shelf_settings.filter_download
shelf_settings.filter_download='downloaded';host.settings:set('shelf',shelf_settings);host.settings:flush()
host:closeWeReadUI();host:showBookshelf()
local filtered=assert(host.shelf_view)
assert(#filtered.books==1 and tostring(filtered.books[1].bookId or filtered.books[1].book_id)==book_id,
    'downloaded filter did not find the native batch')
shelf_settings=host.settings:get('shelf');shelf_settings.filter_download='not_downloaded'
host.settings:set('shelf',shelf_settings);host.settings:flush();host:closeWeReadUI();host:showBookshelf()
filtered=assert(host.shelf_view)
assert(#filtered.books==#input.shelf_books-1,'not-downloaded filter included the native batch')
for _,book in ipairs(filtered.books) do assert(tostring(book.bookId or book.book_id)~=book_id) end
shelf_settings=host.settings:get('shelf');shelf_settings.filter_download=previous_filter
host.settings:set('shelf',shelf_settings);host.settings:flush();host:closeWeReadUI()
-- A local recent event with only native chapters must not dispatch the
-- ordinary Web-backed reader merely because the downloaded badge is true.
local owner=assert(host.library_db:accountKey())
assert(host.settings:patch_reading_state(book_id,{home_recent_at=os.time(),home_recent_account=owner}))
local wrong_reader=false;host.startBookReading=function() wrong_reader=true end
host:showHome();local home_view=assert(host.shelf_view);local recent
for _,book in ipairs(home_view.books) do if tostring(book.bookId or book.book_id)==book_id then recent=book end end
assert(recent and recent._cached);home_view.on_select(recent,'books')
pump(function() return wrong_reader or host._book_detail_view~=nil end)
assert(not wrong_reader and host._book_detail_view,'native-only home item opened the ordinary reader')
host:closeWeReadUI()
local ledger=assert(io.open(home..'/request-count','rb'));local requests=#assert(ledger:read('*a'));assert(ledger:close())
print('WEREAD_BATCH_SHELF='..json.encode{ok=true,mode=input.mode,chapters=count,unavailable=input.total-count,
    missing=missing,requests=requests,source_matches=true,full_plugin=true,shelf_count=#input.shelf_books,
    downloaded_filter=true,home_native_only_safe=true})
