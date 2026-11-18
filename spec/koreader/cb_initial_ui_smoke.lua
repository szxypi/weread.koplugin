-- Actual packaged KOReader ReaderUI against an isolated synthetic service.
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
local socket=require('socket');local settings=Settings:new();local id='CB_SyntheticResume'
local mode=assert(os.getenv('WEREAD_CB_FIRST_MODE'))
local function wait(predicate)
    local deadline=socket.gettime()+45
    while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'first sync timed out') end
end
local Reader=require('apps/reader/readerui')
if os.getenv('WEREAD_CB_FIRST_REOPEN')=='1' then
    local requests=0;Client.request=function() requests=requests+1;error('unexpected offline request') end
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
    local host=assert(FM.instance.weread);host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
    assert(host:startBookReading(assert(settings:get_book(id))))
    wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id end)
    local plugin=Reader.instance.weread;plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local saved=assert(plugin.settings:get_book(id))
    if mode=='normal' or mode=='delayed' then assert(not plugin.source_dispatch:pending(id) and not saved.pending_upload_position)
    else assert(plugin.source_dispatch:pending(id) and (saved.pending_upload_position
        or mode=='verify_save_failed' and saved.last_local_position and saved.last_uploaded_position)) end
    plugin.progress_sync:on_resume();UI:setInputTimeout(0);UI:handleInput()
    assert(not plugin.progress_sync.verified and requests==0,'offline reopen retried first request')
    print('\nWEREAD_CB_FIRST_REOPEN='..Client:new(settings):json_encode({result='PASS',offline=true,requests=requests,
        journal_pending=mode~='normal' and mode~='delayed'}));os.exit(0)
end
settings:update_auth({account={user_vid='900000',name='Synthetic'},cookies={wr_vid='900000',wr_skey='synthetic-cloud-session'}},{replace_cookies=true})
local grant={vid='900000',accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh',deviceId='eink334691225'..string.rep('1',19)}
if mode~='no_native' then assert(require('weread.lib.native_credentials'):new(settings):save(grant,settings:get_auth_scope(),0,0)) end
local client=Client:new(settings);local book={book_id=id,bookId=id,title='合成导入书',author='合成作者'}
Content.ensure_reader_state(client,book);local chapters=Content.fetch_catalog(client,book)
assert(Content.save_catalog_cache(client,settings,book,chapters))
local file=Content.fetch_chapter_epub(client,settings,book,chapters[1])
book.cached_file=file;book.cached_chapters={['1']=file};book.chapters=chapters
settings:set('books',{[id]=book});settings:set('sync',{pull_on_open=false,upload_on_close=false,ask_on_conflict=true,upload_interval_minutes=0})
settings:set('read_report',{enabled=false});local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;settings:set('cache',cache);settings:flush()
local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
local host=assert(FM.instance.weread);assert(host:startBookReading(book))
wait(function() return Reader.instance and Reader.instance.weread and Reader.instance.weread._current_weread_book_id==id end)
local reader=Reader.instance;local plugin=reader.weread
plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
reader.rolling:onGotoPage(2)
wait(function() local value=plugin.source_position:current();return value and value.chapter_uid=='1' end)
local sync=plugin.progress_sync;local choice,box,notice
local show=UI.show
function UI:show(widget,...)
    if choice and widget.cancel_callback==choice.keep_local then box=widget end
    return show(self,widget,...)
end
local original_choice=sync.on_choice
sync.on_choice=function(value) choice=value;original_choice(value) end
sync.notify=function(code,data) notice={code=code,data=data} end
local function first_choice()
    choice,box,notice=nil,nil,nil
    assert(sync:sync_now());wait(function() return choice and box end)
    assert(choice.initialize_cloud and not choice.use_remote and not sync.verified)
    return choice,box
end
local selected,dialog=first_choice();UI:close(dialog);selected.keep_local()
assert(not sync.verified and not sync.uploading and not plugin.source_dispatch:pending(id),'cancel granted first sync')
selected,dialog=first_choice()
if mode=='changed' then
    local http,ltn12=require('socket.http'),require('ltn12');local raw=client:json_encode({progress_offset_delta=1});local out={}
    local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
        headers={['Content-Type']='application/json',['Content-Length']=tostring(#raw)},source=ltn12.source.string(raw),sink=ltn12.sink.table(out)}
    assert(code==200)
end
local persist=sync._persist
if mode=='save_failed' or mode=='verify_save_failed' then
    sync._persist=function(self,book_id,patch)
        if mode=='save_failed' and patch.last_uploaded_position or mode=='verify_save_failed' and patch.verified_source=='cb_upload_confirmed' then
            error('synthetic local save failure')
        end
        return persist(self,book_id,patch)
    end
end
UI:close(dialog);selected.initialize()
wait(function() return not sync.uploading end);sync._persist=persist
local expected_notice=(mode=='normal' or mode=='delayed') and 'upload_success'
    or (mode=='noack' or mode=='noack_unapplied') and 'upload_unconfirmed'
    or (mode=='save_failed' or mode=='verify_save_failed') and 'upload_initial_save_failed' or 'upload_failed'
assert(notice and notice.code==expected_notice,'first sync showed an unexpected result')
if mode=='noack_unapplied' then
    choice,box,notice=nil,nil,nil;assert(sync:sync_now());wait(function() return not sync.pulling and notice~=nil end)
    assert(not choice and notice.code=='upload_unconfirmed' and plugin.source_dispatch:pending(id),
        'manual check offered a repeated first write')
end
local saved=assert(plugin.settings:get_book(id))
if mode=='normal' or mode=='delayed' then
    assert(sync.verified and not plugin.source_dispatch:pending(id) and not saved.pending_upload_position,'confirmed first sync not saved')
elseif mode=='changed' or mode=='native_time' or mode=='no_native' then
    assert(not sync.verified and not plugin.source_dispatch:pending(id) and saved.pending_upload_position,'changed cloud not blocked')
elseif mode=='verify_save_failed' then
    assert(not sync.verified and plugin.source_dispatch:pending(id) and saved.last_uploaded_position and saved.last_local_position,
        'verified save failure lost local position or journal')
else
    assert(not sync.verified and plugin.source_dispatch:pending(id) and saved.pending_upload_position,'uncertain first sync lost journal')
end
plugin.settings:flush()
print('\nWEREAD_CB_FIRST_UI='..client:json_encode({result='PASS',mode=mode,cancelled=true,explicit_choice=true,
    verified=sync.verified==true,journal_pending=plugin.source_dispatch:pending(id),pending=saved.pending_upload_position~=nil}))
os.exit(0)
