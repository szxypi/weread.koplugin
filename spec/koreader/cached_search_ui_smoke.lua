-- Offline search and cross-chapter navigation in a real synthetic reader.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local signed_out=os.getenv('WEREAD_TEST_CACHED_SIGNED_OUT')=='1'
local no_catalog=os.getenv('WEREAD_TEST_CACHED_NO_CATALOG')=='1'
local imported=os.getenv('WEREAD_TEST_SEARCH_CB')=='1'
local book_id=imported and 'CB_SyntheticCached' or '900001'
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader')
Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local settings=require('weread.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
if os.getenv('WEREAD_TEST_CACHED_REOPEN')=='1' then
    local persisted=assert(settings:get_book(book_id))
    local path=assert(persisted.cached_chapters['2'])
    local input=assert(io.open(evidence..'/cached-synthetic-xpointer.txt','rb'))
    local xpointer=input:read('*a');input:close();assert(#xpointer>0 and #xpointer<4096)
    local Client=require('weread.lib.client')
    local ffi=require('ffi')
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local requests=ffi.cast('int *',memory);requests[0]=0
    function Client:request() requests[0]=requests[0]+1;error('offline reopen attempted a network request') end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
        document=require('document/documentregistry'):openDocument(path)}
    UI:show(reader);UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
    assert(reader.document:isXPointerInCurrentPage(xpointer),'reopened chapter lost its saved page')
    local saved=assert(reader.weread.settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_position.chapter_offset==19
        and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid=='1')
    assert(requests[0]==0,'offline reopen attempted a network request')
    print('\nWEREAD_CACHED_SEARCH_REOPEN='..require('json').encode({result='PASS',file_position=true,pending_preserved=true}))
    os.exit(0)
end
if not signed_out then
    settings:update_auth({account={user_vid='900000',name='Synthetic'},
        cookies={wr_vid='900000',wr_skey='synthetic-search-session'}},{replace_cookies=true})
end
local chapters={{chapterUid='1',chapterIdx=1,title='合成第一章',wordCount=1000},
    {chapterUid='2',chapterIdx=2,title='合成第二章',wordCount=1000},
    {chapterUid='3',chapterIdx=3,title='未下载章节',wordCount=1000}}
local book={book_id=book_id,bookId=book_id,bookVersion=7,title='合成本地搜索',chapters=chapters,cached_chapters={}}
local bodies,sources={},{}
for i=1,2 do
    local chapter=chapters[i];local uid=chapter.chapterUid
    bodies[uid]='<html><body><p>chapter '..uid..' '..string.rep('ordinary synthetic text ',80)..'amberneedle distinct ending '..uid..'</p></body></html>'
    sources[uid]=assert(Source.capture(book,chapter,bodies[uid],'web_xhtml'))
    book.cached_chapters[uid]=assert(Content.save_book_epub(settings,book,{chapter},bodies,'cached-search-'..uid,{},nil,nil,Identity.capture(book),sources))
end
book.cached_file=book.cached_chapters['1']
if no_catalog then
    book.chapters=nil
    book.last_local_position={book_id=book_id,chapter_uid='1',chapter_offset=19,percent=12}
    book.pending_upload_position={book_id=book_id,chapter_uid='1',chapter_offset=19,percent=12}
    book.pending_upload_reason='synthetic_pending'
    if not signed_out then
        book.pending_upload_account=require('weread.lib.crypto').sha256_hex('weread-library:900000'):sub(1,20)
    end
end
settings:set('books',{[book_id]=book});settings:set('sync',{pull_on_open=false,upload_on_close=false})
local cache=settings:get('cache',{});cache.auto_prefetch_next_chapter=false;settings:set('cache',cache)
local report=settings:get('read_report',{});report.enabled=false;settings:set('read_report',report);settings:flush()
if not no_catalog then assert(Content.save_catalog_cache(require('weread.lib.client'):new(settings),settings,book,chapters)) end
local Client=require('weread.lib.client')
local ffi=require('ffi')
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local requests=ffi.cast('int *',memory);requests[0]=0
function Client:request() requests[0]=requests[0]+1;error('offline cached search attempted a network request') end
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket')
local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
    document=require('document/documentregistry'):openDocument(book.cached_file)}
UI:show(reader);UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
local function wait(predicate)
    local deadline=socket.gettime()+45
    while not predicate() do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'cached search UI timed out')
    end
end
local plugin=assert(reader.weread)
plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
assert(plugin:showEndOfBookDialog(book_id))
local quick=assert(UI:getTopmostVisibleWidget());local button
for _i,row in ipairs(quick.buttons) do for _j,item in ipairs(row) do
    if item.text==require('weread.lib.i18n').tr('Search downloaded chapters') then button=item end
end end
assert(button and button.enabled~=false);button.callback()
wait(function() return plugin._cached_book_search_owner and plugin._cached_book_search_owner.input end)
local Search=require('weread.lib.cached_book_search');local original=Search.scan
Search.scan=function(...) socket.sleep(.8);return original(...) end
local owner=plugin._cached_book_search_owner
owner.input:setInputText('amberneedle');owner.input.buttons[1][2].callback()
wait(function() return owner.worker and owner.worker.job end)
local pid=owner.worker.job.pid;assert(plugin.busy_message);plugin.busy_message:onTapClose()
wait(function() return require('ffi/util').isSubProcessDone(pid) end)
assert(not owner.job and #owner.value==0);Search.scan=original
owner.menu:onMenuSelect(owner.menu.item_table[1])
wait(function() return owner.finished and not owner.job end)
assert(#owner.value==2 and owner.checked==2 and owner.missing==(no_catalog and 0 or 1))
UI:forceRePaint();Device.screen:shot(evidence..'/cached-search-results.png')
local expected=owner.value[2].offset
owner.menu:onMenuSelect(owner.menu.item_table[2])
wait(function()
    local instance=require('apps/reader/readerui').instance
    if instance and instance.weread then reader=instance;plugin=instance.weread end
    local held=reader and plugin.progress_sync and plugin.progress_sync:current_source_target()
    return reader and reader.document and reader.document.file==book.cached_chapters['2']
        and plugin.source_navigation and plugin.source_navigation.state=='ready'
        and held and held.chapter_uid=='2' and held.chapter_offset==expected
end)
assert(reader.document:isXPointerInCurrentPage(assert(plugin.progress_sync.source_anchor).xpointer))
assert(not plugin.progress_sync.verified and not plugin.read_report.job)
if no_catalog then
    assert(plugin.progress_sync.file_resume and plugin.progress_sync.file_resume.local_only)
    local saved=assert(plugin.settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_position.chapter_offset==19
        and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid=='1')
    assert(plugin.progress_sync:sync_now()==false)
    local xpointer=assert(plugin.progress_sync.source_anchor.xpointer)
    local output=assert(io.open(evidence..'/cached-synthetic-xpointer.txt','wb'))
    assert(output:write(xpointer));assert(output:close())
    plugin:onFlushSettings();reader:onClose(false)
    saved=assert(settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_position.chapter_offset==19
        and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid=='1')
end
assert(requests[0]==0,'offline cached search attempted a network request')
print('\nWEREAD_CACHED_SEARCH_UI='..require('json').encode({result='PASS',results=2,unavailable=no_catalog and 0 or 1,
    navigation=true,cancel_resume=true,signed_out=signed_out,imported=imported,no_catalog=no_catalog}))
os.exit(0)
