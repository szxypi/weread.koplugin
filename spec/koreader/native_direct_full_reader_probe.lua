-- Actual installed plugin + ReaderUI, two isolated chapters, no network.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local Settings=require('weread.lib.settings');local settings=Settings:new()
assert(settings.data_dir==home..'/weread')
settings:set('account',{user_vid='12345678',name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid='12345678',wr_skey='synthetic'});settings:flush()
assert(settings:auth_scope_matches(settings:get_auth_scope()))
local PluginLoader=require('pluginloader')
PluginLoader.enabled_plugins,PluginLoader.disabled_plugins,PluginLoader.loaded_plugins={},{},{}
for _,entry in ipairs(PluginLoader:_discover()) do if entry.name=='weread' then PluginLoader:_load{entry} end end
assert(#PluginLoader.enabled_plugins==1,'candidate plugin was not loaded')
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function pump(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'installed reader navigation timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.first)
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local first=Reader.instance;local host=first.weread
assert(first.document.file==input.first and host.settings.data_dir==settings.data_dir)
assert(not host:detectWeReadBook() and not host._current_weread_book_id)
local report_id,_,reason=host.read_report:resolve_target();assert(not report_id and reason=='native_direct_local_only')
assert(first.document:getPageCount()>2 and first.rolling)
first.rolling:onGotoPage(2);UI:forceRePaint();local anchor=assert(first.document:getXPointer())
local function quick(active,id)
    assert(active:onShowWeReadQuickMenu())
    pump(function()
        local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById(id)~=nil
    end)
    UI:forceRePaint();local button=assert(UI:getTopmostVisibleWidget():getButtonById(id))
    assert(button.enabled~=false);button:onTapSelectButton()
end
quick(host,'next_chapter')
pump(function() return Reader.instance and Reader.instance~=first and Reader.instance.document.file==input.second end)
local second=Reader.instance;host=assert(second.weread)
assert(not host:detectWeReadBook() and not host._current_weread_book_id)
quick(host,'previous_chapter')
pump(function() return Reader.instance and Reader.instance~=second and Reader.instance.document.file==input.first end)
local reopened=Reader.instance;host=assert(reopened.weread);UI:forceRePaint()
assert(reopened.document:isXPointerInCurrentPage(anchor),'local page was not restored after chapter return')
assert(not host:detectWeReadBook() and not host._current_weread_book_id)
G_reader_settings:saveSetting('end_document_action','next_file')
assert(host:handleEndOfBook({}))
pump(function() return Reader.instance and Reader.instance~=reopened and Reader.instance.document.file==input.second end)
assert(not Reader.instance.weread:detectWeReadBook())
print('WEREAD_DIRECT_FULL_READER='..json.encode{ok=true,network_blocked=true,plugin_loaded=true,roundtrip=true,
    native_page_restored=true,end_of_book=true,web_coordinates=false})
