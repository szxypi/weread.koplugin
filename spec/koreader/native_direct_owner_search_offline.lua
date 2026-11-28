-- Installed plugin and real cached chapters; inputs and source stay in tmpfs.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
assert(type(input.token)=='string' and #input.token>=6 and #input.token<=128)
local Settings=require('weread.lib.settings');local settings=Settings:new()
settings:set('account',{user_vid=input.vid,name='Synthetic',login_method='qr'});settings:set('cookies',{})
local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
local cache=settings:get('cache');cache.show_annotations=false;cache.auto_prefetch_next_chapter=false
cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
require('weread.lib.native_read_access').capture=function() error('unexpected credentials') end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local stage='reader'
local function wait(predicate)
    local deadline=socket.gettime()+120
    while not predicate() do
        if socket.gettime()>deadline then print('WEREAD_DIRECT_SEARCH_STAGE='..stage);error('search timeout') end
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.second)
wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread
assert(reader.document.file==input.second and host.settings.data_dir==home..'/weread')
assert(not host:detectWeReadBook());assert(host:onShowWeReadQuickMenu())
stage='quick';wait(function()
    local top=UI:getTopmostVisibleWidget();return top and type(top.getButtonById)=='function' and top:getButtonById('search_cached')
end)
local button=assert(UI:getTopmostVisibleWidget():getButtonById('search_cached'));assert(button.enabled~=false)
button:onTapSelectButton()
stage='input';wait(function() return host._native_direct_search and host._native_direct_search.input end)
local owner=host._native_direct_search;owner.input:setInputText(input.token);owner.input.buttons[1][2].callback()
stage='results';wait(function() return owner.finished and not owner.job end)
assert(owner.checked==2 and owner.unavailable==0)
local selected
for _,value in ipairs(owner.value) do if value.entry.chapter_uid==input.uid then selected=value;break end end
assert(selected,'verified chapter did not return a locatable hit')
local row
for _,item in ipairs(owner.menu.item_table) do
    if item.text==selected.title..' · '..selected.hit.context then row=item;break end
end
assert(row);owner.menu:onMenuSelect(row)
stage='switch';wait(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==input.first end)
local target=Reader.instance;local next_host=assert(target.weread)
stage='locate';wait(function() return not next_host._native_direct_search_incoming and not next_host._native_direct_search_open end)
local matches=assert(target.document:findAllText(input.token,false,0,64,false,0));local visible=false
for _,match in ipairs(matches) do if match.start and target.document:isXPointerInCurrentPage(match.start) then visible=true end end
assert(visible,'independent text search did not find token on opened page')
print('WEREAD_DIRECT_OWNER_SEARCH='..json.encode{ok=true,network_blocked=true,credentials_not_required=true,
    installed_plugin=true,cross_chapter=true,independent_text=true})
