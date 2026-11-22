-- Real KOReader dialogs and workers; account-scoped navigation, optionally offline.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
if input.mode~='online' then assert(dofile(arg[1]..'/spec/koreader/offline_network_guard.lua')()) end
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');local socket=require('socket');local home=assert(os.getenv('KO_HOME'))
local scope={vid='12345678',epoch=1};local online=input.mode=='online'
local settings={data_dir=home,cache_dir=home,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_book=function() return nil end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
local Access=require('weread.lib.native_read_access');local original=Access.capture
if online then
    local store={read=function() return input.credentials,1,nil,false end}
    Access.capture=function(s,existing) return original(s,existing or store) end
else Access.capture=function() error('offline navigation requested credentials') end end
local client=require('weread.lib.client'):new(settings);local request=client.request
client.request=function(self,options)
    assert(online,'offline navigation requested network')
    local url,headers=options.url,options.headers or {}
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    assert((url=='https://i.weread.qq.com/book/info?bookId=42' and options.method=='GET')
        or (url=='https://i.weread.qq.com/book/chapterInfos' and options.method=='POST')
        or (url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1 and options.method=='GET')
        or (require('weread.lib.native_chapter_remote').allowed(url)==url and options.method=='GET'
            and not headers.vid and not headers.accessToken and not headers.Cookie))
    return request(self,options)
end
local base=require('ui/widget/infomessage'):new{text='Fixture'};base.modal=false;UI:show(base)
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end,getChapters=function() return {} end},ui={document={file=input.first}},
    isNetworkConnected=function() return online end,
    showBusy=function(self,label,cancel) self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message) end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self,message) self.message=message end,showOffline=function() error('unexpected offline') end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,
    openFile=function(self,path) self.opened=path;self.ui.document={file=path};self._reader_session_gen=self._reader_session_gen+1 end,
    onShowWeReadQuickMenu=require('weread.ui.reader_navigation').onShowWeReadQuickMenu}
local tr=require('weread.lib.plugin_util').tr
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native reader navigation timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local function press(id)
    assert(host:onShowWeReadQuickMenu())
    wait(function()
        local top=UI:getTopmostVisibleWidget()
        return host.message or host._native_direct_navigation and host._native_direct_navigation.entry
            and not host.busy_message and top and type(top.getButtonById)=='function'
    end)
    assert(not host.message)
    local dialog=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
    local action=assert(dialog:getButtonById(id))
    assert(action.enabled~=false);action:onTapSelectButton()
end
press('next_chapter')
wait(function() return host.opened or host.message end)
if input.mode=='gap' then
    assert(not host.opened and host.message==tr('The adjacent chapter is not saved. Connect to download it.'))
else
    assert(host.opened and (input.mode=='online' or host.opened==input.second))
    local second=host.opened
    if input.mode=='two' then
        host.opened=nil
        press('previous_chapter');wait(function() return host.opened or host.message end)
        assert(not host.message and host.opened==input.first)
        host.opened=nil;host.ui.document={file=second};host._reader_session_gen=host._reader_session_gen+1
        G_reader_settings:saveSetting('end_document_action','next_file')
        assert(require('weread.lib.reader_lifecycle').handleEndOfBook(host,{}))
        wait(function() return host.opened or host.message end)
        assert(not host.opened and host.message==tr('The adjacent chapter is not saved. Connect to download it.'))
    end
end
print('WEREAD_DIRECT_NAV_RESULT='..json.encode{ok=true,mode=input.mode,path=host.opened or ''})
