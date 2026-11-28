-- Installed ReaderUI with a real source and an isolated incomplete copy.
-- The profile uses a synthetic offline cookie and has no network access.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local Settings=require('weread.lib.settings');local settings=Settings:new()
assert(settings.data_dir==home..'/weread')
settings:set('account',{user_vid=input.vid,name='Offline fixture',login_method='qr'})
settings:set('cookies',{['wr_'..'vid']=input.vid,wr_skey='synthetic-offline-cookie'});settings:flush()
local PluginLoader=require('pluginloader')
PluginLoader.enabled_plugins,PluginLoader.disabled_plugins,PluginLoader.loaded_plugins={},{},{}
for _,entry in ipairs(PluginLoader:_discover()) do if entry.name=='weread' then PluginLoader:_load{entry} end end
assert(#PluginLoader.enabled_plugins==1)
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local tr=require('weread.lib.plugin_util').tr
local function pump(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'owner copy reader timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local function page(reader,number)
    assert(reader.rolling and reader.document:getPageCount()>1,'chapter has no second page')
    reader.rolling:onGotoPage(number);UI:forceRePaint()
    assert(reader:getCurrentPage()==number,'reader did not move to the requested page')
    return assert(reader.document:getXPointer())
end
local function previous(reader)
    local host=assert(reader.weread);assert(host:onShowWeReadQuickMenu())
    pump(function() local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById('previous_chapter') end)
    UI:getTopmostVisibleWidget():getButtonById('previous_chapter'):onTapSelectButton()
    pump(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==input.first end)
    return Reader.instance
end
local function next_copy(reader,path,missing)
    local host=assert(reader.weread);assert(host:onShowWeReadQuickMenu())
    pump(function() local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById('next_chapter') end)
    UI:getTopmostVisibleWidget():getButtonById('next_chapter'):onTapSelectButton()
    pump(function() return host._native_direct_navigation and host._native_direct_navigation.menu end)
    local menu=host._native_direct_navigation.menu;assert(#menu.item_table==2)
    local wanted=missing and tr('%1 images unavailable'):gsub('%%1','1') or tr('No missing images')
    local selected
    for _,item in ipairs(menu.item_table) do if item.text:find(wanted,1,true) then selected=item end end
    assert(selected);menu:onMenuSelect(selected)
    pump(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==path end)
    return Reader.instance
end
Reader:showReader(input.first)
print('WEREAD_COPY_READER_STAGE=open')
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local first=Reader.instance;local first_anchor=page(first,2)
print('WEREAD_COPY_READER_STAGE=first_page')
local complete=next_copy(first,input.second,false);local complete_anchor=page(complete,2)
print('WEREAD_COPY_READER_STAGE=complete_page')
first=previous(complete);assert(first.document:isXPointerInCurrentPage(first_anchor))
local incomplete=next_copy(first,input.missing_copy,true);local incomplete_anchor=page(incomplete,1)
print('WEREAD_COPY_READER_STAGE=incomplete_page')
first=previous(incomplete);assert(first.document:isXPointerInCurrentPage(first_anchor))
complete=next_copy(first,input.second,false);assert(complete:getCurrentPage()==2 and complete.document:isXPointerInCurrentPage(complete_anchor))
first=previous(complete)
incomplete=next_copy(first,input.missing_copy,true);assert(incomplete:getCurrentPage()==1 and incomplete.document:isXPointerInCurrentPage(incomplete_anchor))
print('WEREAD_DIRECT_OWNER_COPY_READER='..json.encode{ok=true,offline=true,installed_plugin=true,distinct_positions=true})
