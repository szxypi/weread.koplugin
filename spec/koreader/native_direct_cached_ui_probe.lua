-- Fresh KOReader process: choose a saved chapter without credentials or network.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(arg[1]..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');local socket=require('socket');local home=assert(os.getenv('KO_HOME'))
local test=assert(arg[2]);local path=assert(arg[3]);local scope={vid=test=='other' and '87654321' or '12345678',epoch=1}
local settings={data_dir=home,cache_dir=home,get=function(_,_,default) return default end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
require('weread.lib.native_read_access').capture=function() error('offline lookup requested credentials') end
local client=require('weread.lib.client'):new(settings)
client.request=function() error('offline lookup attempted a network request') end
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return scope.vid end},ui={},isNetworkConnected=function() return false end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
    end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self,message) self.message=message end,showOffline=function() error('unexpected offline error') end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function(self,file) self.opened=file end}
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'offline chapter UI timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
host:showBookMenu({book_id='42',title='Synthetic native book',author='Fixture',chapters={}})
local detail=assert(host._book_detail_view);local action
local tr=require('weread.lib.plugin_util').tr
local label=test=='normal' and 'Read E-Ink chapter' or 'Read saved E-Ink chapter'
for _,button in ipairs(detail._action_buttons) do if button.text==tr(label) then action=button end end
assert(action and action.enabled~=false);action.callback()
wait(function() return host.message or host._native_direct_reading and host._native_direct_reading.menu end)
if test=='other' or test=='bad-entry' then
    assert(host.message==tr('No usable saved E-Ink chapters for this book and account. Existing files are kept.') and not host.opened)
else
    local menu=assert(host._native_direct_reading.menu)
    if test=='copies' then
        assert(#menu.item_table==2 and menu.item_table[1].text~=menu.item_table[2].text)
    else assert(#menu.item_table==1) end
    if test=='damage' then local file=assert(io.open(path,'ab'));assert(file:write('corrupt'));assert(file:close()) end
    if test=='switch' then scope={vid='87654321',epoch=2} end
    menu:onMenuSelect(menu.item_table[test=='copies' and 2 or 1])
    if test=='switch' then
        assert(not host.opened and not host._native_direct_worker.job)
    else
        wait(function() return host.opened or host.message end)
        if test=='damage' or test=='bad-receipt' then
            assert(not host.opened and host.message==tr('The saved E-Ink chapter is damaged or has changed. The file was kept.'))
            assert(require('libs/libkoreader-lfs').attributes(path))
        else assert(host.opened==path) end
    end
end
print('WEREAD_DIRECT_CACHED_UI='..require('json').encode{ok=true,case=test,network_blocked=true})
