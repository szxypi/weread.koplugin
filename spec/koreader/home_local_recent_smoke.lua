-- Open an off-shelf synthetic book through the plugin, then resume from home.
-- The second process has no server and reuses only the isolated test profile.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local switch=os.getenv('WEREAD_TEST_HOME_ACCOUNT_SWITCH')=='1'
local switch_reopen=os.getenv('WEREAD_TEST_HOME_ACCOUNT_REOPEN')=='1'
local reopen=os.getenv('WEREAD_TEST_HOME_REOPEN')=='1' or switch or switch_reopen
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local settings=require('weread.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
if not reopen then
    settings:update_auth({account={user_vid='900000',name='Synthetic'},
        cookies={wr_vid='900000',wr_skey='synthetic-home-session'}},{replace_cookies=true})
    local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
    local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
    local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
end
local ffi=require('ffi');pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local requests=ffi.cast('int *',memory);requests[0]=0
local Client=require('weread.lib.client')
function Client:request() requests[0]=requests[0]+1;error('local home attempted a network request',0) end
local Common=require('weread.ui.common')
Common.isNetworkOnline=function() return false end;Common.isNetworkConnected=Common.isNetworkOnline
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket,json=require('socket'),require('json')
local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
local id='900099'
local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
local function pump(predicate)
    local deadline=socket.gettime()+45
    while not predicate() do assert(socket.gettime()<deadline,'home local reading deadline');tick() end
end
local function host() if not FM.instance then FM:showFiles(home) end;return assert(FM.instance.weread) end
local function close_reader()
    local reader=assert(Reader.instance)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    reader.weread:onFlushSettings();reader:onClose(false);assert(not Reader.instance)
end
local function press(view,label)
    local tr=require('weread.lib.plugin_util').tr
    for _i,buttons in ipairs({view._action_buttons or {},view._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do if button.text==tr(label) then assert(button.enabled~=false);button.callback();return end end
    end
    error('missing reading action',0)
end
FM:showFiles(home)
local plugin=host();local account=assert(plugin.library_db:accountKey())
if switch or switch_reopen then
    local Reading=require('weread.ui.book_reading');local Progress=require('weread.lib.shelf_progress')
    -- Mock settings intentionally reset to account 900000 on construction;
    -- select the second synthetic account again in the fresh process.
    if switch_reopen then
        plugin.settings:update_auth({account={user_vid='900002',name='Other synthetic'},
            cookies={wr_vid='900002',wr_skey='synthetic-other-session'}},{replace_cookies=true})
    end
    if switch then
        local books=plugin.settings:get('books',{});local book=assert(books[id])
        book.recent_read_account=account;book.recent_read_at=10
        book.home_recent_account=nil;book.home_recent_at=nil;book.last_local_account=nil
        book.last_local_position={book_id=id,chapter_uid='1',percent=33}
        book.pending_upload_position={book_id=id,chapter_uid='1',percent=33}
        book.pending_upload_account=nil;book.pending_upload_reason='synthetic-legacy'
        plugin.settings:set('books',books);plugin.settings:flush()
        plugin.settings:update_auth({account={user_vid='900002',name='Other synthetic'},
            cookies={wr_vid='900002',wr_skey='synthetic-other-session'}},{replace_cookies=true})
        assert(plugin.settings:get_auth_scope(true).vid=='900002','synthetic account switch not persisted')
        assert(plugin.library_db:accountKey()~=account)
        assert(plugin:recordRecentReading(id))
    end
    local book=assert(plugin.settings:get_book(id));local current=assert(plugin.library_db:accountKey())
    assert(book.recent_read_account~=current and book.home_recent_account==current and book.pending_upload_account==nil)
    assert(book.last_local_position.percent==33 and book.pending_upload_position.percent==33
        and book.pending_upload_reason=='synthetic-legacy','home event changed legacy checkpoints')
    local positions=Reading.local_positions(book,current)
    assert(not next(positions[1]) and not next(positions[2]),'foreign legacy position was selected')
    assert(Progress.display(book,{percent=12},current,id)==12,'foreign pending progress was shown')
    if switch_reopen then
        plugin.settings:update_auth({account={user_vid='900000',name='Synthetic'},
            cookies={wr_vid='900000',wr_skey='synthetic-home-session'}},{replace_cookies=true})
        assert(plugin.settings:get_auth_scope(true).vid=='900000','synthetic account restoration not persisted')
        local original=assert(plugin.library_db:accountKey())
        assert(original==book.recent_read_account and Reading.local_positions(book,original)[1].percent==33)
        assert(Progress.display(book,{percent=12},original,id)==33,'original account lost pending checkpoint')
        plugin.settings:update_auth({account={},cookies={}},{replace_cookies=true})
        assert(plugin:recordRecentReading(id))
        book=assert(plugin.settings:get_book(id))
        assert(book.home_recent_account=='' and book.recent_read_account==original
            and book.pending_upload_position.percent==33,'signed-out event changed original ownership')
    end
    assert(requests[0]==0)
    print('\nWEREAD_HOME_ACCOUNT_SWITCH='..json.encode({result='PASS',reopen=switch_reopen,
        legacy_pending_preserved=true,legacy_position_preserved=true,foreign_hidden=true,requests=0}))
    os.exit(0)
end
local path,xpointer
if not reopen then
    local chapters={{chapterUid='1',chapterIdx=1,title='合成章节',wordCount=1000}}
    local paragraphs={};for i=1,200 do paragraphs[#paragraphs+1]='<p>合成测试段落 '..i..'，仅用于验证本地阅读。</p>' end
    local body='<html><body>'..table.concat(paragraphs)..'</body></html>'
    local book={book_id=id,bookId=id,bookVersion=1,title='合成本机读物',author='合成作者',chapters=chapters,cached_chapters={}}
    local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
    local source={['1']=assert(Source.capture(book,chapters[1],body,'web_xhtml'))}
    local Content=require('weread.lib.content')
    path=assert(Content.save_book_epub(settings,book,chapters,{['1']=body},'home-recent',{},nil,nil,Identity.capture(book),source))
    book.cached_full_book=path;book.cached_file=path;book.cached_chapters['1']=path
    assert(Content.save_catalog_cache(plugin.client,settings,book,chapters))
    local books=settings:get('books',{});books[id]=book
    books['900098']={book_id='900098',title='其他账号',recent_read_at=os.time()+10,recent_read_account='other-owner'}
    books['900097']={book_id='900097',title='其他账号资料',recent_read_at=os.time()+20,recent_read_account=account,_library_account_key='other-owner'}
    settings:set('books',books);settings:flush()
    assert(plugin.library_db:cacheShelf({{bookId='900001',title='合成书架',readUpdateTime=1}},{}))
    plugin:showHome();assert(#plugin.shelf_view.books==1,'unread off-shelf book appeared')
    plugin:closeWeReadUI();plugin:showBookRecord(book,{verified_metadata=true})
    press(assert(plugin._book_detail_view),'▤ Read')
    pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==path end)
    pump(function() local b=Reader.instance.weread.settings:get_book(id);return b and b.home_recent_account==account end)
    local reader=Reader.instance;assert(reader.document:getPageCount()>3)
    reader.rolling:onGotoPage(3);tick();xpointer=assert(reader.document:getXPointer())
    close_reader()
    local f=assert(io.open(evidence..'/home-recent-xpointer.txt','wb'));f:write(xpointer);f:close()
else
    local f=assert(io.open(evidence..'/home-recent-xpointer.txt','rb'));xpointer=f:read('*a');f:close()
    path=assert(settings:get_book(id).cached_full_book)
end
plugin=host();plugin:closeWeReadUI();plugin:showHome()
local view=assert(plugin.shelf_view);local selected
for _i,row in ipairs(view.books) do
    local row_id=tostring(row.bookId or row.book_id)
    assert(row_id~='900098' and row_id~='900097','foreign account appeared on home')
    if row_id==id then selected=row end
end
assert(selected and selected._cached and view.books[1]==selected,'local recent book missing or not first')
assert(#assert(plugin.library_db:getShelf())==1 and plugin.library_db:getShelf()[1].bookId=='900001','cloud shelf changed')
UI:forceRePaint();view.on_select(selected,'books')
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==path end)
local reader=Reader.instance
pump(function() return reader.weread.progress_sync.current_book_id==id end)
assert(reader.document:isXPointerInCurrentPage(xpointer),'home selection lost the saved page')
close_reader();plugin=host()
assert(#assert(plugin.library_db:getShelf())==1 and plugin.library_db:getShelf()[1].bookId=='900001','reading altered cloud shelf')
assert(requests[0]==0,'local home attempted network')
print('\nWEREAD_HOME_LOCAL_RECENT='..json.encode({result='PASS',reopen=reopen,home_selection=true,
    account_isolation=true,shelf_unchanged=true,saved_page=true,requests=0}))
os.exit(0)
