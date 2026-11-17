-- Packaged reader, synthetic account and HTTP service: paginate and navigate.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local missing=os.getenv('WEREAD_TEST_SEARCH_MISSING')=='1'
local catalog_missing=os.getenv('WEREAD_TEST_SEARCH_CATALOG_MISSING')=='1'
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
settings:update_auth({account={user_vid='900000',name='Synthetic'},
    cookies={wr_vid='900000',wr_skey='synthetic-search-session'}},{replace_cookies=true})
local chapters={{chapterUid='1',chapterIdx=1,title='合成第一章',wordCount=1000},
    {chapterUid='2',chapterIdx=2,title='合成第二章',wordCount=1000}}
local book={book_id='900001',bookId='900001',bookVersion=7,title='合成书内搜索',chapters=chapters,cached_chapters={}}
local bodies,sources={},{ }
for _i,chapter in ipairs(chapters) do
    local uid=chapter.chapterUid
    bodies[uid]='<html><body><p>chapter '..uid..' '..string.rep('ordinary synthetic text ',80)..'amberneedle</p></body></html>'
    sources[uid]=assert(Source.capture(book,chapter,bodies[uid],'web_xhtml'))
    if not missing or uid=='1' then
        book.cached_chapters[uid]=Content.save_book_epub(settings,book,{chapter},bodies,'search-'..uid,{},nil,nil,Identity.capture(book),sources)
    end
end
book.cached_file=book.cached_chapters['1']
if catalog_missing then book.chapters=nil end
settings:set('books',{['900001']=book})
settings:set('sync',{pull_on_open=false,upload_on_close=false})
local cache=settings:get('cache',{});cache.auto_prefetch_next_chapter=false;settings:set('cache',cache)
local report=settings:get('read_report',{});report.enabled=false;settings:set('read_report',report);settings:flush()
if not catalog_missing then assert(Content.save_catalog_cache(require('weread.lib.client'):new(settings),settings,book,chapters)) end
local ffi=require('ffi')
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local network=ffi.cast('int *',memory);network[0]=0
local Client=require('weread.lib.client');local request=Client.request
function Client:request(options) network[0]=network[0]+1;return request(self,options) end
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket')
local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
    document=require('document/documentregistry'):openDocument(book.cached_file)}
UI:show(reader)
UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
local function wait(predicate)
    local deadline=socket.gettime()+30
    while not predicate() do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'book search UI timed out')
    end
end
local plugin=assert(reader.weread)
plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
assert(plugin:showEndOfBookDialog('900001'))
local quick=assert(UI:getTopmostVisibleWidget())
local button
for _i,row in ipairs(quick.buttons) do for _j,item in ipairs(row) do
    if item.text==require('weread.lib.i18n').tr('Search entire book') then button=item end
end end
assert(button and button.enabled~=false);button.callback()
wait(function() return plugin._book_search_owner and plugin._book_search_owner.input end)
local Search=require('weread.lib.book_search')
-- A cancelled first request must not dispatch after the busy indicator closes.
local original_fetch=Search.fetch
Search.fetch=function(...) socket.sleep(.8);return original_fetch(...) end
local original_reader=Content.ensure_reader_state
if catalog_missing then Content.ensure_reader_state=function(...) socket.sleep(.8);return original_reader(...) end end
local before_cancel=tonumber(network[0])
local owner=plugin._book_search_owner;owner.input:setInputText('amberneedle');owner.input.buttons[1][2].callback()
wait(function() return owner.worker and owner.worker.job end)
local cancelled_pid=owner.worker.job.pid;assert(plugin.busy_message)
plugin.busy_message:onTapClose()
wait(function() return require('ffi/util').isSubProcessDone(cancelled_pid) end)
assert(not owner.job and tonumber(network[0])==before_cancel,'cancelled search dispatched a request')
Search.fetch=original_fetch
Content.ensure_reader_state=original_reader
owner.menu:onMenuSelect(owner.menu.item_table[1])
wait(function() return owner.state and owner.state.pages==1 and not owner.job end)
assert(#owner.value==1 and owner.value[1].source_verified==false)
local worker_used=owner.worker~=nil
assert(owner.menu.item_table[1].text==require('weread.lib.i18n').tr('Load more results'))
owner.menu:onMenuSelect(owner.menu.item_table[1])
wait(function() return owner.state.pages==2 and not owner.job end)
assert(owner.state.finished and #owner.value==2 and owner.value[2].chapter_uid=='2')
UI:forceRePaint();Device.screen:shot(evidence..'/book-search-results.png')
local expected=assert(require('weread.lib.book_search_target').project(bodies['2'],'900001',owner.value[2]))
local before_navigation=tonumber(network[0])
owner.menu:onMenuSelect(owner.menu.item_table[2])
if missing then
    wait(function() return owner.navigation and owner.navigation.confirm end)
    assert(tonumber(network[0])==before_navigation,'lookup requested network before download confirmation')
    local confirmation=owner.navigation.confirm
    assert(confirmation.text==require('weread.lib.i18n').tr('No matching downloaded chapter. Download it and locate this search result?'))
    confirmation.cancel_callback();assert(not owner.navigation and tonumber(network[0])==before_navigation)
    owner.menu:onMenuSelect(owner.menu.item_table[2])
    wait(function() return owner.navigation and owner.navigation.confirm end)
    assert(tonumber(network[0])==before_navigation,'cancelled confirmation started a download')
    owner.navigation.confirm.ok_callback()
end
wait(function()
    local instance=require('apps/reader/readerui').instance
    if instance and instance.weread then reader=instance;plugin=instance.weread end
    local held=reader and plugin.progress_sync and plugin.progress_sync:current_source_target()
    return reader and reader.document and (missing or reader.document.file==book.cached_chapters['2'])
        and plugin.source_navigation and plugin.source_navigation.state=='ready'
        and held and held.chapter_uid=='2' and held.chapter_offset==expected.chapter_offset
end)
assert(reader.document:isXPointerInCurrentPage(assert(plugin.progress_sync.source_anchor).xpointer))
assert(not plugin.progress_sync.verified and not plugin.read_report.job)
assert(not missing or tonumber(network[0])>before_navigation)
print('\nWEREAD_BOOK_SEARCH_UI='..require('json').encode({result='PASS',pages=2,results=2,
    verified_navigation=true,network_worker=worker_used,downloaded=missing,catalog_downloaded=catalog_missing}))
os.exit(0)
