-- Three isolated ReaderUI processes share only their synthetic local profile.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local Settings=require('weread.lib.settings');local settings=Settings:new()
settings:set('account',{user_vid='12345678',name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid='12345678',wr_skey='synthetic'})
local sync=settings:get('sync',{});sync.pull_on_open=true;sync.upload_on_close=false;sync.upload_interval_minutes=0
settings:set('sync',sync);settings:flush()
local Common=require('weread.ui.common')
Common.isNetworkConnected=function() return input.stage~='save' end;Common.isNetworkOnline=Common.isNetworkConnected
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,entry in ipairs(loader:_discover()) do if entry.name=='weread' then loader:_load{entry} end end
assert(#loader.enabled_plugins==1)
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function pump(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native offline reminder timed out: '..input.stage)
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.first)
pump(function()
    local reader=Reader.instance;local host=reader and reader.weread
    return host and host._native_direct_reconnect and host._native_direct_reconnect.entry
end)
local reader=Reader.instance;local host=reader.weread;local owner=host._native_direct_reconnect
local store=require('weread.lib.native_direct_pending');local scope=host.settings:get_auth_scope()
local function read() return store.read(host.library_db,host.settings,scope,owner.entry,function() return true end) end
if input.stage=='save' then
    reader.rolling:onGotoPage(1);host:onPageUpdate();owner.baseline=require('weread.lib.source_context').location(reader.document,'page')
    reader.rolling:onGotoPage(3);host:onPageUpdate()
    assert(owner.offline and owner.dirty,'offline turn was not detected')
    local anchor=assert(require('weread.lib.source_context').location(reader.document,'page')).xpointer
    local entry=owner.entry;reader:onClose(false);assert(not Reader.instance)
    local value=assert(store.read(host.library_db,host.settings,scope,entry,function() return true end))
    assert(value.xpointer==anchor,'close did not preserve the offline position')
    local cache=require('weread.lib.native_direct_cache')
    local rows=assert(cache.list(host.settings,scope.vid,entry.book_id,function() return true end))
    assert(store.mark(host.library_db,host.settings,scope,entry.book_id,rows,function() return true end))
    local found=false
    for _,row in ipairs(rows) do if row.key==entry.key and row.copy==entry.copy then found=row.pending_offline==true end end
    assert(found,'saved chapter did not show its pending-position hint')
elseif input.stage=='different' then
    pump(function() return owner.record and owner.dialog end)
    local record=assert(read());assert(reader.document:isXPointerInCurrentPage(record.xpointer),'local page was not restored')
    local button=assert(owner.dialog:getButtonById('reconnect_later'));button:onTapSelectButton()
    assert(read(),'later removed an offline reminder')
    reader.rolling:onGotoPage(1);host:onPageUpdate();assert(read(),'moving the page deleted the reminder')
    reader:onClose(false)
elseif input.stage=='restore' then
    pump(function() return owner.record and owner.dialog end)
    local record=assert(read());assert(not reader.document:isXPointerInCurrentPage(record.xpointer),'different page was not saved')
    local restore=assert(owner.dialog:getButtonById('reconnect_restore'));restore:onTapSelectButton()
    pump(function() return owner.dialog and owner.dialog:getButtonById('reconnect_cloud') end)
    assert(reader.document:isXPointerInCurrentPage(record.xpointer),'offline anchor was not restored')
    local button=assert(owner.dialog:getButtonById('reconnect_later'));button:onTapSelectButton()
    assert(read(),'later removed the restored reminder')
    -- The actual sync flow calls this only after a confirmed or identical cloud position.
    local point=require('weread.lib.source_context').location(reader.document,'page')
    require('weread.ui.native_direct_reconnect').synced(host,owner.entry,point)
    assert(not read(),'confirmed matching position did not clear the reminder')
    reader:onClose(false)
elseif input.stage=='cleared' then
    assert(not read() and not owner.record,'a removed reminder returned after restart')
    reader:onClose(false)
else error('unknown stage') end
print('WEREAD_DIRECT_PENDING_READER='..json.encode{ok=true,stage=input.stage,network_blocked=true})
