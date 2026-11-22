-- Fresh isolated process reopens a real-account native chapter without network or credentials.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(assert(arg[2])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local input=require('json').decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,get=function(_,_,default) return default end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
require('weread.lib.native_read_access').capture=function() error('offline lookup requested credentials') end
local client=require('weread.lib.client'):new(settings)
client.request=function() error('offline lookup attempted network access') end
local UI=require('ui/uimanager');local socket=require('socket')
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end},ui={},isNetworkConnected=function() return false end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
    end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self) self.failed=true end,showOffline=function(self) self.failed=true end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function(self,path) self.opened=path end}
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native direct owner offline UI timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
host:showBookMenu({book_id=input.book_id,title='Synthetic native book',author='Fixture',chapters={}})
local detail=assert(host._book_detail_view);local action
local label=require('weread.lib.plugin_util').tr('Read saved E-Ink chapter')
for _,button in ipairs(detail._action_buttons) do if button.text==label then action=button end end
assert(action and action.enabled~=false);action.callback()
wait(function() return host.failed or host._native_direct_reading and host._native_direct_reading.menu end)
assert(not host.failed)
local menu=assert(host._native_direct_reading.menu)
local cache=require('weread.lib.native_direct_cache')
local rows=assert(cache.list(settings,scope.vid,input.book_id,function() return true end))
assert(#rows==#menu.item_table);local index
for i,row in ipairs(rows) do
    local file=cache.open(settings,scope.vid,input.book_id,row,function() return true end)
    if file and file.path==input.path then assert(not index);index=i end
end
assert(index);menu:onMenuSelect(menu.item_table[index]);wait(function() return host.failed or host.opened end)
assert(not host.failed and host.opened==input.path and not host._native_direct_reading)
print('WEREAD_DIRECT_OWNER_CACHED_UI='..require('json').encode{ok=true,network_blocked=true,credentials_not_required=true})
