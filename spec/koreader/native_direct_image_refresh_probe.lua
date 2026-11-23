-- Installed plugin + ReaderUI against a strictly synthetic loopback service.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1' or os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local Settings=require('weread.lib.settings');local settings=Settings:new()
assert(settings.data_dir==home..'/weread')
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{})
local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
local cache=settings:get('cache');cache.show_annotations=false;cache.auto_prefetch_next_chapter=false
cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
local Access=require('weread.lib.native_read_access');local original=Access.capture
local credentials={read=function() return input.credentials,1,nil,false end}
Access.capture=function(value,store) return original(value,store or credentials) end
local Client=require('weread.lib.client');local client_new=Client.new
Client.new=function(self,value) value.mock_endpoint=input.mock_endpoint;return client_new(self,value) end
if input.owner then
    local request=Client.request
    Client.request=function(self,options)
        local url,headers=options.url,options.headers or {};local base='https://i.weread.qq.com'
        assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        if url==base..'/book/info?bookId='..input.book_id then assert(options.method=='GET')
        elseif url==base..'/book/chapterInfos' then
            local body=json.decode(options.body)
            assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
                and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
        elseif url:find(base..'/book/chapterdownload?',1,true)==1 then
            assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
                and url:find('chapters=0%2C'..input.uid..'&',1,true)
                and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
        else
            assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
                and not headers.vid and not headers.accessToken and not headers.Cookie)
        end
        if url:find(base,1,true)==1 then
            assert(headers.vid==input.credentials.vid and headers.accessToken==input.credentials.accessToken)
        end
        return request(self,options)
    end
end
local PluginLoader=require('pluginloader')
PluginLoader.enabled_plugins,PluginLoader.disabled_plugins,PluginLoader.loaded_plugins={},{},{}
for _,entry in ipairs(PluginLoader:_discover()) do if entry.name=='weread' then PluginLoader:_load{entry} end end
assert(#PluginLoader.enabled_plugins==1)
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function pump(predicate)
    local deadline=socket.gettime()+120
    while not predicate() do
        assert(socket.gettime()<deadline,'image retry timed out')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.path)
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread
host.settings.mock_endpoint=input.mock_endpoint;host.isNetworkConnected=function() return true end
if input.scenario then host.showInfo=function(self,message) self._test_refresh_message=message end end
assert(reader.document:getPageCount()>1);reader.rolling:onGotoPage(2);UI:forceRePaint()
local anchor=assert(reader.document:getXPointer());local old_path=reader.document.file
assert(host:onShowWeReadQuickMenu())
pump(function() local top=UI:getTopmostVisibleWidget()
    return top and type(top.getButtonById)=='function' and top:getButtonById('native_refresh_images') end)
local dialog=UI:getTopmostVisibleWidget();UI:forceRePaint()
local button=assert(dialog:getButtonById('native_refresh_images'));assert(button.enabled~=false)
assert(button.dimen and button.dimen.x>=0 and button.dimen.y>=0
    and button.dimen.x+button.dimen.w<=Device.screen:getWidth()
    and button.dimen.y+button.dimen.h<=Device.screen:getHeight(),'image retry button is outside the screen')
local close=assert(dialog:getButtonById('close_book'))
assert(close.dimen and close.dimen.y>=0 and close.dimen.y+close.dimen.h<=Device.screen:getHeight(),
    'quick menu extends beyond the screen')
button:onTapSelectButton()
pump(function() return host._native_direct_image_refresh~=nil end)
pump(function() return not host._native_direct_image_refresh and not host.busy_message end)
assert(Reader.instance==reader and reader.document.file==old_path and reader.document:isXPointerInCurrentPage(anchor))
local account=assert(host.settings:get_auth_scope()).vid
local Cache=require('weread.lib.native_direct_cache')
local rows=assert(Cache.list(host.settings,account,input.book_id or '42',function() return true end))
if input.scenario then
    local tr=require('weread.lib.plugin_util').tr
    local expected=input.scenario=='rate' and 'WeRead is limiting requests. Please try again later.'
        or 'No additional images could be recovered. The current chapter was kept.'
    assert(host._test_refresh_message==tr(expected) and #rows==1 and rows[1].missing_images==1)
    print('WEREAD_DIRECT_IMAGE_REFRESH='..json.encode{ok=true,scenario=input.scenario,page_unchanged=true,original_kept=true})
    return
end
assert(#rows==2)
local original_copy,improved
for _,entry in ipairs(rows) do
    local saved=assert(Cache.open(host.settings,account,input.book_id or '42',entry,function() return true end))
    if entry.missing_images==(input.initial_missing or 1) then original_copy=saved
    else assert(entry.missing_images==0);improved=saved end
end
assert(original_copy and improved and original_copy.path==old_path and improved.path~=old_path
    and original_copy.source_sha256==improved.source_sha256)
print('WEREAD_DIRECT_IMAGE_REFRESH='..json.encode{ok=true,path=improved.path,original_kept=true,
    page_unchanged=true,source_equal=true,missing_before=input.initial_missing or 1,missing_after=0})
