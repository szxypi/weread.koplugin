-- Packaged reader, synthetic account and HTTP service: paginate and navigate.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local missing=os.getenv('WEREAD_TEST_SEARCH_MISSING')=='1'
local catalog_missing=os.getenv('WEREAD_TEST_SEARCH_CATALOG_MISSING')=='1'
local renewal_test=os.getenv('WEREAD_TEST_SEARCH_RENEWAL')=='1'
local imported=os.getenv('WEREAD_TEST_SEARCH_CB')=='1'
local current_fallback=os.getenv('WEREAD_TEST_SEARCH_CURRENT_FALLBACK')=='1'
local local_download=os.getenv('WEREAD_TEST_SEARCH_LOCAL_DOWNLOAD')=='1'
local book_id=imported and 'CB_SyntheticResume' or '900001'
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
local book={book_id=book_id,bookId=book_id,bookVersion=7,title='合成书内搜索',chapters=chapters,cached_chapters={}}
local bodies,sources={},{ }
for _i,chapter in ipairs(chapters) do
    local uid=chapter.chapterUid
    bodies[uid]='<html><body><p>chapter '..uid..' '..string.rep('ordinary synthetic text ',80)..'amberneedle</p></body></html>'
    sources[uid]=assert(Source.capture(book,chapter,bodies[uid],'web_xhtml'))
    if not missing or uid=='1' then
        book.cached_chapters[uid]=Content.save_book_epub(settings,book,{chapter},bodies,'search-'..uid,{},nil,nil,Identity.capture(book),sources)
    end
end
book.cached_file=book.cached_chapters[current_fallback and '2' or '1']
if catalog_missing then book.chapters=nil end
settings:set('books',{[book_id]=book})
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
local last_info
if renewal_test then
    local show_info=plugin.showInfo
    function plugin:showInfo(message,...) last_info=message;return show_info(self,message,...) end
end
assert(plugin:showEndOfBookDialog(book_id))
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
local control,count
if renewal_test then
    local http,ltn12=require('socket.http'),require('ltn12')
    local endpoint=settings.mock_endpoint
    control=function(value)
        local bytes=plugin.client:json_encode(value)
        local _,code=http.request{url=endpoint..'/__control',proxy=endpoint,method='POST',
            headers={['content-type']='application/json',['content-length']=#bytes},source=ltn12.source.string(bytes),sink=ltn12.sink.null()}
        assert(code==200)
    end
    count=function(path)
        local chunks={};local _,code=http.request{url=endpoint..'/__state',proxy=endpoint,sink=ltn12.sink.table(chunks)}
        assert(code==200);local total=0
        for _i,value in ipairs(plugin.client:json_decode(table.concat(chunks)).totals) do
            if value.path==path then total=total+value.count end
        end
        return total
    end
    control{match='/web/book/search_v2',times=1,status=401,web_renewal_mode='rotate'}
end
owner.menu:onMenuSelect(owner.menu.item_table[1])
if current_fallback then
    wait(function() return owner.fallback_attempted and owner.state.pages==2 and not owner.job end)
    assert(#owner.value==1 and owner.value[1].chapter_uid=='2' and owner.state.finished)
    local expected=assert(require('weread.lib.book_search_target').project(bodies['2'],book_id,owner.value[1]))
    owner.menu:onMenuSelect(owner.menu.item_table[1])
    wait(function()
        local held=plugin.progress_sync and plugin.progress_sync:current_source_target()
        return not owner.navigation and plugin.source_navigation and plugin.source_navigation.state=='ready'
            and held and held.chapter_uid=='2' and held.chapter_offset==expected.chapter_offset
    end)
    assert(reader.document:isXPointerInCurrentPage(assert(plugin.progress_sync.source_anchor).xpointer))
    assert(not plugin.progress_sync.verified and not plugin.read_report.job)
    print('\nWEREAD_BOOK_SEARCH_UI='..require('json').encode({result='PASS',pages=2,results=1,
        verified_navigation=true,network_worker=true,downloaded=false,catalog_downloaded=catalog_missing,
        imported_search=true,current_fallback=true}))
    os.exit(0)
end
wait(function() return owner.state and owner.state.pages==1 and not owner.job end)
assert(#owner.value==1 and owner.value[1].source_verified==false)
if imported then
    assert(owner.menu.item_table[#owner.menu.item_table].text==require('weread.lib.i18n').tr('Search results may be incomplete for this book.'))
    if local_download then
        local function action(menu,label)
            for _i,item in ipairs(menu.item_table) do
                if item.text==require('weread.lib.i18n').tr(label) then return item end
            end
            error('search action missing: '..label)
        end
        local before=tonumber(network[0]);owner.menu:onMenuSelect(action(owner.menu,'Search downloaded chapters'))
        wait(function() return plugin._cached_book_search_owner and plugin._cached_book_search_owner.input end)
        local cached=plugin._cached_book_search_owner
        assert(cached.input:getInputText()=='amberneedle');cached.input.buttons[1][2].callback()
        wait(function() return cached.finished and not cached.job end)
        assert(#cached.value==1 and cached.missing==1 and tonumber(network[0])==before)
        cached.menu:onMenuSelect(action(cached.menu,'Download full book and search again'))
        local confirm=assert(cached.download.confirm);confirm.cancel_callback()
        assert(not cached.download and tonumber(network[0])==before,'cancelled full download started network activity')
        cached.menu:onMenuSelect(action(cached.menu,'Download full book and search again'))
        confirm=assert(cached.download.confirm);confirm.ok_callback()
        wait(function() return cached.finished and not cached.job and not cached.download and cached.checked==2 end)
        assert(#cached.value==2 and cached.missing==0 and tonumber(network[0])>before,'full download did not fill search coverage')
        assert(reader.document.file==book.cached_file,'download replaced the current reader document')
        local expected=cached.value[2].offset;cached.menu:onMenuSelect(cached.menu.item_table[2])
        wait(function()
            local instance=require('apps/reader/readerui').instance
            if instance and instance.weread then reader=instance;plugin=instance.weread end
            local held=plugin.progress_sync and plugin.progress_sync:current_source_target()
            return plugin.source_navigation and plugin.source_navigation.state=='ready'
                and held and held.chapter_uid=='2' and held.chapter_offset==expected
        end)
        assert(reader.document:isXPointerInCurrentPage(assert(plugin.progress_sync.source_anchor).xpointer))
        assert(not plugin.progress_sync.verified and not plugin.read_report.job)
        print('\nWEREAD_BOOK_SEARCH_UI='..require('json').encode({result='PASS',local_download_search=true,
            unavailable_before=1,results=2,cancel_safe=true,current_file_preserved=true,navigation_verified=true}))
        os.exit(0)
    end
    if not missing and not renewal_test then
        local local_action
        for _i,item in ipairs(owner.menu.item_table) do
            if item.text==require('weread.lib.i18n').tr('Search downloaded chapters') then local_action=item end
        end
        assert(local_action,'imported online results have no local search action')
        local network_before=tonumber(network[0]);owner.menu:onMenuSelect(local_action)
        wait(function() return plugin._cached_book_search_owner and plugin._cached_book_search_owner.input end)
        local cached=plugin._cached_book_search_owner
        assert(not plugin._book_search_owner and cached.input:getInputText()=='amberneedle','local search lost the query')
        cached.input.buttons[1][2].callback()
        wait(function() return cached.finished and not cached.job end)
        assert(#cached.value==2 and tonumber(network[0])==network_before,'downloaded search missed results or used network')
        plugin:cancelBookSearch()
        assert(require('weread.ui.book_search').open(plugin,book_id,chapters))
        owner=assert(plugin._book_search_owner);owner.input:setInputText('amberneedle');owner.input.buttons[1][2].callback()
        wait(function() return owner.state and owner.state.pages==1 and not owner.job end)
        assert(#owner.value==1,'online search did not reopen after downloaded search')
    end
end
if renewal_test then
    assert(not owner.recovery and count('/web/login/renewal')==1 and count('/web/book/search_v2')==2)
    assert(plugin.settings:get('cookies').wr_skey=='XXXrenewed-native' and plugin.web_renewal.store:read().phase=='done')
    control{match='/web/book/search_v2',times=-1,status=401,web_renewal_mode='rotate'}
    owner.menu:onMenuSelect(owner.menu.item_table[1])
    wait(function() return not owner.job and not owner.recovery end)
    assert(owner.state.pages==1 and #owner.value==1 and count('/web/login/renewal')==2
        and count('/web/book/search_v2')==4,'repeated 401 lost the page or retried renewal')
    assert(last_info==require('weread.lib.i18n').tr('The search login is unavailable. Check your login and try again. Existing results are kept.'))
    owner.menu:onMenuSelect(owner.menu.item_table[1])
    wait(function() return not owner.job and not owner.recovery end)
    assert(owner.state.pages==1 and #owner.value==1 and count('/web/login/renewal')==2
        and count('/web/book/search_v2')==5,'manual retry renewed an unchanged failed page')
    control{match='/web/book/search_v2',times=1,status=429}
    owner.menu:onMenuSelect(owner.menu.item_table[1])
    wait(function() return not owner.job and not owner.recovery end)
    assert(owner.state.pages==1 and #owner.value==1 and count('/web/login/renewal')==2
        and count('/web/book/search_v2')==6,'429 retried login or lost the page')
    assert(last_info==require('weread.lib.i18n').tr('Search requests are temporarily limited. Wait and try again. Existing results are kept.'))
    control{match='',times=0,delay=0}
end
local worker_used=owner.worker~=nil
assert(owner.menu.item_table[1].text==require('weread.lib.i18n').tr('Load more results'))
owner.menu:onMenuSelect(owner.menu.item_table[1])
wait(function() return owner.state.pages==2 and not owner.job end)
assert(owner.state.finished and #owner.value==2 and owner.value[2].chapter_uid=='2')
UI:forceRePaint();Device.screen:shot(evidence..'/book-search-results.png')
local expected=assert(require('weread.lib.book_search_target').project(bodies['2'],book_id,owner.value[2]))
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
local result={result='PASS',pages=2,results=2,
    verified_navigation=true,network_worker=worker_used,downloaded=missing,catalog_downloaded=catalog_missing}
if renewal_test then result.renewal_scenarios=true end
if imported then result.imported_search=true end
print('\nWEREAD_BOOK_SEARCH_UI='..require('json').encode(result))
os.exit(0)
