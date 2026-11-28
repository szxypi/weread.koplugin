-- Synthetic imported-book cloud viewing through the real plugin host.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local Settings=require('weread.lib.settings');local Client=require('weread.lib.client')
local Content=require('weread.lib.content');local Source=require('weread.lib.position_source')
local Dom=require('weread.lib.source_dom');local id='CB_SyntheticResume'
local single=os.getenv('WEREAD_TEST_CB_CLOUD_SINGLE')=='1'
local settings=Settings:new();assert(settings.mock_endpoint)
if os.getenv('WEREAD_TEST_CB_CLOUD_REOPEN')=='1' then
    local evidence=assert(os.getenv('WEREAD_EVIDENCE'))
    local input=assert(io.open(evidence..'/cb-cloud-view-xpointer.txt','r'))
    local xpointer=assert(input:read('*a'));input:close()
    local book=assert(settings:get_book(id))
    local requests=0
    Client.request=function() requests=requests+1;error('unexpected offline request') end
    local socket=require('socket')
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
    local host=assert(FM.instance.weread)
    host.isNetworkOnline=function() return false end;host.isNetworkConnected=function() return false end
    assert(host:startBookReading(book))
    local Reader=require('apps/reader/readerui');local deadline=socket.gettime()+45
    while not (Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id
        and Reader.instance.document:isXPointerInCurrentPage(xpointer)) do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'offline imported cloud view reopen timed out')
    end
    local plugin=Reader.instance.weread;local saved=assert(plugin.settings:get_book(id))
    assert(saved.pending_upload_position and saved.pending_upload_position.chapter_uid=='1'
        and saved.pending_upload_reason=='synthetic_pending','offline reopen lost pending intent')
    assert(not plugin.progress_sync.verified and requests==0,'offline reopen enabled upload or made requests')
    print('\nWEREAD_CB_CLOUD_REOPEN='..Client:new(settings):json_encode({result='PASS',fresh_process=true,
        offline=true,pending_preserved=true,upload_disabled=true,requests=requests}))
    os.exit(0)
end
settings:update_auth({account={user_vid='900000',name='Synthetic'},
    cookies={wr_vid='900000',wr_skey='synthetic-cloud-session'}},{replace_cookies=true})
local client=Client:new(settings)
local book={book_id=id,bookId=id,title='合成导入书',author='合成作者'}
Content.ensure_reader_state(client,book)
local chapters=Content.fetch_catalog(client,book)
assert(Content.save_catalog_cache(client,settings,book,chapters))
local file
if single then
    file=Content.fetch_chapter_epub(client,settings,book,chapters[1])
    book.cached_file=file;book.cached_chapters={['1']=file}
else
    file=Content.fetch_chapters_epub(client,settings,book,chapters,{suffix='cb-cloud-view'})
    book.cached_file,book.cached_full_book=file,file
end
book.chapters=chapters
settings:set('books',{[id]=book});settings:set('sync',{pull_on_open=false,upload_on_close=false})
settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
local socket=require('socket')
local function wait(predicate)
    local deadline=socket.gettime()+45
    while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'imported cloud view timed out') end
end
local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
local host=assert(FM.instance.weread);assert(host:startBookReading(book))
local Reader=require('apps/reader/readerui')
wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id end)
local reader=Reader.instance;local plugin=reader.weread;local document=reader.document
plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=function() return true end
local http,ltn12=require('socket.http'),require('ltn12');local chunks={}
local _,code=http.request{url=settings.mock_endpoint..'/__state',proxy=settings.mock_endpoint,sink=ltn12.sink.table(chunks)}
assert(code==200);local remote=client:json_decode(table.concat(chunks)).progress[id]
local target_offset=assert(tonumber(os.getenv('WEREAD_TEST_CB_CLOUD_TARGET')))
local approximate=os.getenv('WEREAD_TEST_CB_CLOUD_GAP')=='1'
assert(approximate and remote.chapterOffset<target_offset or not approximate and remote.chapterOffset==target_offset)
if not single then assert(Source.read_document(document,id,6));reader.rolling:onGotoPage(1) end
local pending={book_id=id,chapter_uid='1',chapter_idx=1,percent=3}
local account=assert(plugin.library_db:accountKey())
assert(plugin.settings:patch_reading_state(id,{pending_upload_position=pending,pending_upload_reason='synthetic_pending',
    pending_upload_account=account}))
assert(plugin:showCloudSourcePosition())
if single then
    wait(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
    plugin.cloud_source_request.confirm:onClose()
    assert(not plugin.cloud_source_request and reader.document.file==file,'cancel changed the current chapter')
    assert(plugin:showCloudSourcePosition())
    wait(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
    local previous=reader
    plugin.cloud_source_request.confirm.ok_callback()
    wait(function()
        if Reader.instance and Reader.instance~=previous and Reader.instance.weread then
            reader=Reader.instance;plugin=reader.weread;document=reader.document
        end
        local held=reader~=previous and plugin.source_position and plugin.source_position:current()
        return held and held.chapter_uid=='6' and not plugin.cloud_source_request and not plugin.cloud_source_incoming
    end)
end
wait(function() return not plugin.cloud_source_request end)
local reference=assert(Dom.open(document,id,6));local target=assert(reference:locate(target_offset))
assert(document:isXPointerInCurrentPage(target.xpointer),'imported cloud target was not visible')
local source=assert(plugin.source_position:current())
assert(source.chapter_uid=='6' and source.chapter_offset==target_offset and not source.upload_verified)
plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=function() return true end
local preview_done,preview,receipt,preview_error=false,nil,nil,nil
assert(plugin.source_position:prepare_cb_current_preview(function(candidate,why,checked)
    preview_done,preview,preview_error,receipt=true,candidate,why,checked
end))
wait(function() return preview_done end)
assert(preview and receipt and not preview_error,'imported source preview failed: '..tostring(preview_error))
assert(plugin.source_position:is_current_cb_preview(receipt,preview),'imported source preview expired')
assert(not plugin.source_position:is_current_upload_preview(receipt,preview)
    and not plugin.source_position:upload_preview_deadline(receipt,preview),'imported preview enabled uploading')
local saved=assert(plugin.settings:get_book(id))
assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_reason=='synthetic_pending')
assert(not plugin.progress_sync.verified,'read-only viewing enabled uploading')
local xpointer=assert(target.xpointer)
reader:onClose(false)
saved=assert(settings:get_book(id))
assert(saved.pending_upload_position and saved.pending_upload_position.chapter_uid=='1'
    and saved.pending_upload_reason=='synthetic_pending','closing after cloud view lost prior pending intent')
assert(host:startBookReading(saved))
wait(function() return Reader.instance and Reader.instance~=reader and Reader.instance.weread
    and Reader.instance.weread._current_weread_book_id==id end)
reader=Reader.instance;plugin=reader.weread
assert(reader.document:isXPointerInCurrentPage(xpointer),'reopening lost the viewed cloud location')
assert(not plugin.progress_sync.verified,'reopening granted upload authority')
local output=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/cb-cloud-view-xpointer.txt','w'))
output:write(xpointer);output:close();reader:onClose(false)
print('\nWEREAD_CB_CLOUD_VIEW='..client:json_encode({result='PASS',native_navigation=true,pending_preserved=true,
    upload_disabled=true,local_reopen=true,download_confirmed=single,approximate=approximate,source_preview=true}))
os.exit(0)
