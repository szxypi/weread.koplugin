-- Installed plugin + ReaderUI position check against a local synthetic service.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new();assert(settings.data_dir==home..'/weread')
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid = input.credentials.vid,wr_skey='synthetic-web-access'});settings:flush()
local scope=assert(settings:get_auth_scope());assert(settings:auth_scope_matches(scope))
assert(require('weread.lib.native_credentials'):new(settings):save(input.credentials,scope,0,1))
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
assert(#loader.enabled_plugins==1)
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native position UI timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.path)
wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread
host.settings.mock_endpoint=input.mock_endpoint
host.isNetworkConnected=function() return true end
local requests=host.client.request
host.client.request=function(self,options)
    local url=options.url;assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
    assert(url=='https://i.weread.qq.com/book/info?bookId=42'
        or url=='https://i.weread.qq.com/book/chapterInfos'
        or url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1
        or url=='https://weread.qq.com/api/userInfo?userVid=12345678'
        or url=='https://weread.qq.com/web/book/chapterInfos'
        or url:find('https://weread.qq.com/web/reader/',1,true)==1
        or url:find('https://weread.qq.com/web/book/chapter/e_',1,true)==1)
    return requests(self,options)
end
local native_worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=65536,timeout=180}
local captured,point
host._native_direct_position_worker={cancel=function() native_worker:cancel() end,start=function(_,task,callback)
    local ctx=assert(host._native_direct_position);captured={text=ctx.input.text,offset=ctx.input.point_offset}
    return native_worker:start(task,function(value) point=value.position;callback(value) end)
end}
host.showInfo=function(self,message) self.checked_message=message end
local function open_menu()
    assert(host:onShowWeReadQuickMenu())
    wait(function()
        local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById('native_position_check')~=nil
    end)
    UI:forceRePaint();assert(UI:getTopmostVisibleWidget():getButtonById('native_position_check')):onTapSelectButton()
end
open_menu()
if input.mode=='move' then
    wait(function() return native_worker.job~=nil end)
    assert(reader.rolling and reader.document:getPageCount()>2);reader.rolling:onGotoPage(2);UI:forceRePaint()
    wait(function() return native_worker.job==nil end)
    assert(not host.checked_message and not host._native_direct_position,'changed page accepted a stale result')
else
    wait(function() return host.checked_message~=nil end)
    local tr=require('weread.lib.plugin_util').tr
    if input.mode=='mismatch' then
        assert(host.checked_message==tr('The chapter source changed, so the reading position could not be checked.') and not point)
    else
        assert(host.checked_message==tr('The local reading position was checked against the chapter source. Cloud sync is not enabled yet.'))
        assert(point and point.upload_verified==false and point.source_current and point.basis=='filtered_xhtml_utf16')
    end
end
print('WEREAD_POSITION_READER='..json.encode{ok=true,mode=input.mode,text=captured and captured.text or '',
    point_offset=captured and captured.offset or 0,offset=point and point.chapter_offset or -1})
