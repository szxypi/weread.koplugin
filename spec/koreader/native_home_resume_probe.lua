-- Installed plugin, synthetic chapter, separate offline processes.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new()
if input.mode=='record' then
    settings:set('account',{user_vid='12345678',name='Synthetic',login_method='qr'})
    settings:set('cookies',{wr_vid='12345678',wr_skey='synthetic'})
    local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
    local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report)
    settings:set('books',{['42']={book_id='42',title='Synthetic book',author='Fixture'}});settings:flush()
elseif input.mode=='switch' then
    settings:update_auth({account={user_vid='87654321',name='Other'},cookies={wr_vid='87654321',wr_skey='synthetic-other'}},
        {replace_cookies=true});settings:flush()
end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket')
local Reader=require('apps/reader/readerui');local FM=require('apps/filemanager/filemanager')
local function pump(fn)
    local deadline=socket.gettime()+90
    while not fn() do
        assert(socket.gettime()<deadline,'native home timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
if input.mode=='record' then
    Reader:showReader(input.path)
    pump(function() return Reader.instance and Reader.instance.weread end)
    local reader=Reader.instance
    pump(function() local b=reader.weread.settings:get_book('42');return b and b.native_home_resume end)
    assert(not reader.weread:detectWeReadBook())
    reader.rolling:onGotoPage(3);UI:forceRePaint()
    local file=assert(io.open(home..'/anchor','wb'));assert(file:write(assert(reader.document:getXPointer())));file:close()
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    reader.weread:onFlushSettings();reader:onClose(false)
    assert(not Reader.instance)
else
    FM:showFiles(home);local host=assert(FM.instance.weread)
    host:showHome();local view=assert(host.shelf_view);local selected
    for _,book in ipairs(view.books) do if book.bookId=='42' then selected=book end end
    if input.mode=='switch' then
        assert(not selected,'other account saw native home history')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    assert(selected and selected.title=='Synthetic book','native chapter not listed on home')
    local message
    if input.mode=='damage' then host.showInfo=function(_,text) message=text end end
    view.on_select(selected,'books')
    if input.mode=='damage' then
        pump(function() return message~=nil end)
        assert(not Reader.instance,'damaged native chapter opened')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==input.path end)
    local reader=Reader.instance
    local file=assert(io.open(home..'/anchor','rb'));local anchor=assert(file:read('*a'));file:close()
    assert(reader.document:isXPointerInCurrentPage(anchor),'native page was not restored')
    assert(not reader.weread:detectWeReadBook(),'native resume gained Web position authority')
end
print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
os.exit(0)
