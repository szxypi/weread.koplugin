-- Packaged plugin widgets and actual background worker, using a synthetic server.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local UI=require('ui/uimanager');local socket=require('socket')
local function pump(predicate)
    local deadline=socket.gettime()+100
    while not predicate() do
        assert(socket.gettime()<deadline,'native batch timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
if input.mode=='offline' or input.mode=='offline_locked' or input.mode=='offline_partial' then
    assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
    local cache=require('weread.lib.native_direct_cache')
    local rows=assert(cache.list(settings,scope.vid,'42',function() return true end))
    assert(#rows==(input.mode=='offline_partial' and 1 or input.mode=='offline_locked' and 2 or 3))
    local seen={};local cache_dir
    for _,row in ipairs(rows) do
        local saved=assert(cache.open(settings,scope.vid,'42',row,function() return true end))
        cache_dir=assert(saved.path:match('^(.*)/[^/]+/[^/]+$'))
        local doc=assert(require('document/documentregistry'):openDocument(saved.path))
        assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
        local hits=assert(doc:findAllText('Chapter '..row.chapter_uid..', synthetic paragraph',false,0,8,false,0))
        assert(hits[1],'saved chapter content did not render');doc:close();seen[row.chapter_uid]=true
    end
    assert(seen['37'] and (seen['38']~=nil)==(input.mode~='offline_partial')
        and (seen['39']~=nil)==(input.mode=='offline'))
    cache.MAX_ENTRIES=3
    local lfs=require('libs/libkoreader-lfs')
    local added={}
    for index=1,4-#rows do
        local path=cache_dir..'/synthetic-damaged-'..index
        assert(lfs.mkdir(path));added[#added+1]=path
        local remaining=cache.remaining(settings,scope.vid,'42',function() return true end)
        if index==4-#rows then assert(remaining==nil,'overfull cache accepted')
        else assert(remaining==3-#rows-index,'incorrect cache capacity') end
    end
    for _,path in ipairs(added) do assert(lfs.rmdir(path)) end
    print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode,network_blocked=true});os.exit(0)
end
local client=require('weread.lib.client'):new(settings)
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end,getChapters=function() return {} end},ui={},
    isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
    end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self,message) self.message=message end,
    showOffline=function() error('unexpected offline') end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function() error('batch unexpectedly opened reader') end}
host:showBookMenu({book_id='42',title='Synthetic',author='Fixture',chapters={}})
local view=assert(host._book_detail_view);local action
for _,button in ipairs(view._action_buttons) do
    if button.text==require('weread.lib.plugin_util').tr('Download E-Ink chapters') then action=button end
end
assert(action);action.callback()
pump(function() return host._native_direct_reading and host._native_direct_reading.confirm end)
local confirm=host._native_direct_reading.confirm
if input.mode=='cancel' then
    confirm.cancel_callback();UI:close(confirm)
    assert(not host._native_direct_reading and not host.busy_message)
elseif input.mode=='stale' then
    scope={vid='87654321',epoch=2}
    confirm.ok_callback();UI:close(confirm)
    assert(not host._native_direct_reading and not host.busy_message,'old confirmation started after account change')
else
    confirm.ok_callback();UI:close(confirm)
    if input.mode=='cancel_running' then
        pump(function()
            local ctx=host._native_direct_reading;local file=io.open(home..'/hold','rb')
            if file then file:close() end
            return ctx and (ctx.batch_progress or -1)>=33 and file~=nil
        end)
        local ctx=host._native_direct_reading
        ctx.busy.buttons[1][1].callback()
        assert(not host._native_direct_reading and not host.busy_message)
        print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode});os.exit(0)
    end
    pump(function() return host.message~=nil end)
    local text=host.message
    if input.mode=='fail' then
        assert(text==require('weread.lib.plugin_util').tr('WeRead is limiting requests. Completed chapters were kept; try again later.'))
    else
        local T=require('weread.lib.plugin_util').T;local tr=require('weread.lib.plugin_util').tr
        local template=tr('E-Ink chapters ready: %1 downloaded, %2 already saved, %3 unavailable. %4 chapters have missing images.')
        local downloaded=input.mode=='resume' and '2' or input.mode=='locked' and '2' or '0'
        local saved=input.mode=='resume' and '1' or input.mode=='locked' and '0' or '3'
        assert(text==T(template,downloaded,saved,input.mode=='locked' and '1' or '0','0'),text)
    end
    assert(not host._native_direct_reading and not host.busy_message)
end
print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode})
