-- Offline real-account neighboring chapters; no credentials or network.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(assert(arg[2])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));local scope={vid=input.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,get=function(_,_,default) return default end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
require('weread.lib.native_read_access').capture=function() error('offline navigation requested credentials') end
local client=require('weread.lib.client'):new(settings);client.request=function() error('offline network') end
local UI=require('ui/uimanager');local socket=require('socket')
local base=require('ui/widget/infomessage'):new{text='Fixture'};base.modal=false;UI:show(base)
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end},ui={document={file=input.first}},
    isNetworkConnected=function() return false end,
    showBusy=function(self,label,cancel) self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message) end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self) self.failed=true end,
    openFile=function(self,path) self.opened=path;self.ui.document={file=path};self._reader_session_gen=self._reader_session_gen+1 end,
    onShowWeReadQuickMenu=require('weread.ui.reader_navigation').onShowWeReadQuickMenu}
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'owner offline navigation timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local function press(id)
    assert(host:onShowWeReadQuickMenu())
    wait(function()
        local top=UI:getTopmostVisibleWidget()
        return host.failed or host._native_direct_navigation and host._native_direct_navigation.entry
            and not host.busy_message and top and type(top.getButtonById)=='function'
    end)
    assert(not host.failed)
    UI:forceRePaint();local button=assert(UI:getTopmostVisibleWidget():getButtonById(id))
    assert(button.enabled~=false);button:onTapSelectButton()
    wait(function() return host.failed or host.opened end);assert(not host.failed)
end
press('next_chapter');assert(host.opened==input.second);host.opened=nil
press('previous_chapter');assert(host.opened==input.first)
print('WEREAD_DIRECT_OWNER_NEIGHBOR_OFFLINE='..json.encode{ok=true,network_blocked=true,credentials_not_required=true,roundtrip=true})
