-- Full imported-book manual sync through the normal plugin and mock server.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local Settings=require('weread.lib.settings');local Client=require('weread.lib.client');local Content=require('weread.lib.content')
local settings=Settings:new();assert(settings.mock_endpoint)
local id='CB_SyntheticResume'
if os.getenv('WEREAD_TEST_CB_SYNC_REOPEN')=='1' then
    local requests=0;Client.request=function() requests=requests+1;error('unexpected offline request') end
    local socket=require('socket');local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
    local host=assert(FM.instance.weread);host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
    assert(host:startBookReading(assert(settings:get_book(id))))
    local Reader=require('apps/reader/readerui');local deadline=socket.gettime()+45
    while not (Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id) do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'offline CB sync reopen timed out')
    end
    local plugin=Reader.instance.weread
    plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local saved=assert(plugin.settings:get_book(id))
    assert(plugin.source_dispatch:pending(id) and saved.pending_upload_position
        and saved.pending_upload_reason=='upload_readback_unconfirmed','fresh process lost uncertain position')
    plugin.progress_sync:on_resume();UI:setInputTimeout(0);UI:handleInput()
    assert(not plugin.progress_sync.verified and requests==0,'offline restart retried an uncertain upload')
    print('\nWEREAD_CB_SYNC_REOPEN='..Client:new(settings):json_encode({result='PASS',fresh_process=true,
        journal_preserved=true,pending_preserved=true,automatic_disabled=true,requests=requests}))
    os.exit(0)
end
settings:update_auth({account={user_vid='900000',name='Synthetic'},cookies={wr_vid='900000',wr_skey='synthetic-cloud-session'}},{replace_cookies=true})
local client=Client:new(settings)
local book={book_id=id,bookId=id,title='合成导入书',author='合成作者'}
Content.ensure_reader_state(client,book);local chapters=Content.fetch_catalog(client,book)
assert(Content.save_catalog_cache(client,settings,book,chapters))
local single=os.getenv('WEREAD_TEST_CB_CLOUD_SINGLE')=='1'
local noack=os.getenv('WEREAD_TEST_CB_SYNC_NOACK')=='1'
local cloud=os.getenv('WEREAD_TEST_CB_SYNC_CLOUD')=='1'
local file
if single then
    file=Content.fetch_chapter_epub(client,settings,book,chapters[1]);book.cached_file=file;book.cached_chapters={['1']=file}
else
    file=Content.fetch_chapters_epub(client,settings,book,chapters,{suffix='cb-manual-sync'});book.cached_file=file;book.cached_full_book=file
end
book.chapters=chapters;settings:set('books',{[id]=book})
settings:set('sync',{pull_on_open=false,upload_on_close=false,ask_on_conflict=true})
settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
local socket=require('socket')
local function wait(predicate)
    local deadline=socket.gettime()+45
    while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'imported manual sync timed out') end
end
local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
local host=assert(FM.instance.weread);assert(host:startBookReading(book))
local Reader=require('apps/reader/readerui')
wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id end)
local reader=Reader.instance;local plugin=reader.weread
plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
reader.rolling:onGotoPage(2)
wait(function() local point=plugin.source_position:current();return point and point.chapter_uid=='1' end)
local original=assert(plugin.source_position:current())
local sync=plugin.progress_sync;local choice,box,notice
local show=UI.show
function UI:show(widget,...)
    if choice and widget.cancel_callback==choice.keep_local then box=widget end
    return show(self,widget,...)
end
local old_choice=sync.on_choice
sync.on_choice=function(value) choice=value;old_choice(value) end
sync.notify=function(code,data) notice={code=code,data=data} end
local http,ltn12=require('socket.http'),require('ltn12')
local function control(value)
    local text=client:json_encode(value);local output={}
    local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
        headers={['Content-Type']='application/json',['Content-Length']=tostring(#text)},source=ltn12.source.string(text),sink=ltn12.sink.table(output)}
    assert(code==200)
end
local function select_local()
    choice,box,notice=nil,nil,nil
    assert(sync:sync_now());wait(function() return choice and box end)
    UI:close(box);choice.keep_local()
end
choice,box,notice=nil,nil,nil
if cloud then
    local local_point=assert(sync:capture_local());local account=assert(plugin.library_db:accountKey())
    assert(plugin.settings:patch_reading_state(id,{pending_upload_position=local_point,pending_upload_reason='synthetic_pending',
        pending_upload_account=account}))
end
assert(sync:sync_now());wait(function() return choice and box end)
if cloud then
    UI:close(box);choice.use_remote()
    if single then
        wait(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
        plugin.cloud_source_request.confirm.ok_callback()
    end
    local target=assert(tonumber(os.getenv('WEREAD_TEST_CB_CLOUD_TARGET')))
    wait(function()
        if Reader.instance and Reader.instance.weread then reader=Reader.instance;plugin=reader.weread end
        local point=plugin.source_position and plugin.source_position:current()
        return point and point.chapter_uid=='6' and point.chapter_offset==target
            and not plugin.cloud_source_request and not plugin.cloud_source_incoming
    end)
    local saved=assert(plugin.settings:get_book(id))
    assert(saved.pending_upload_position and saved.pending_upload_reason=='synthetic_pending','cloud choice lost local intent')
    assert(not plugin.progress_sync.verified and not plugin.progress_sync.interval.task,'cloud choice enabled automatic uploads')
    reader:onClose(false)
    print('\nWEREAD_CB_SYNC_CLOUD='..client:json_encode({result='PASS',choice=true,native_navigation=true,
        pending_preserved=true,automatic_disabled=true,single=single}))
    os.exit(0)
end
control({progress_offset_delta=1});UI:close(box);choice.keep_local()
wait(function() return notice~=nil end)
assert(notice.code=='upload_failed' and notice.data.error=='source_remote_changed','changed cloud did not stop upload')
assert(not sync.verified and not plugin.source_dispatch:pending(id),'failed source check enabled sending')
control({progress_offset_delta=0,progress_confirmation=noack and 'noack' or 'plain'})
select_local();wait(function() return notice~=nil end)
assert(notice.code==(noack and 'upload_unconfirmed' or 'upload_success'),
    'explicit local sync returned unexpected status: '..tostring(notice.data and notice.data.error))
local chunks={};local _,code=http.request{url=settings.mock_endpoint..'/__state',proxy=settings.mock_endpoint,sink=ltn12.sink.table(chunks)}
assert(code==200);local server=client:json_decode(table.concat(chunks));local remote=server.progress[id]
assert(tostring(remote.chapterUid)==original.chapter_uid and remote.chapterOffset==original.chapter_offset,'cloud did not receive native point')
assert(not sync.verified and not sync.interval.task,'manual sync enabled automatic writes')
local saved=assert(plugin.settings:get_book(id))
if noack then
    assert(plugin.source_dispatch:pending(id) and saved.pending_upload_position
        and saved.pending_upload_reason=='upload_readback_unconfirmed','unknown result lost its journal')
    sync:on_resume();UI:setInputTimeout(0);UI:handleInput()
else
    assert(not plugin.source_dispatch:pending(id) and not saved.pending_upload_position,'confirmed sync retained pending state')
end
reader:onClose(false)
print('\nWEREAD_CB_MANUAL_SYNC='..client:json_encode({result='PASS',choice=true,changed_remote_stopped=true,
    explicit_upload=true,native_point=true,pending_cleared=not noack,journal_cleared=not noack,
    automatic_disabled=true,single=single,uncertain=noack}))
os.exit(0)
