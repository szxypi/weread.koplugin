-- Real KOReader menu and subprocess, synthetic native HTTP, local-only EPUB.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local data=input.plugin_home and home..'/weread' or home
if input.plugin_home then require('libs/libkoreader-lfs').mkdir(data) end
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=data,cache_dir=data,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local original=Access.capture
Access.capture=function(s,existing) return original(s,existing or store) end
local client=require('weread.lib.client'):new(settings);local raw=client.request
client.request=function(self,options)
    local url=options.url
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    assert((url=='https://i.weread.qq.com/book/info?bookId=42' and options.method=='GET')
        or (url=='https://i.weread.qq.com/book/chapterInfos' and options.method=='POST')
        or (url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1 and options.method=='GET')
        or (require('weread.lib.native_chapter_remote').allowed(url)==url and options.method=='GET'
            and not options.headers.vid and not options.headers.accessToken and not options.headers.Cookie))
    return raw(self,options)
end
local UIManager=require('ui/uimanager')
local socket=require('socket')
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native direct UI timeout')
        UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
    end
end
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end},ui={},isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel}
        UIManager:show(self.busy_message)
    end,
    closeBusy=function(self) UIManager:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(_,message) error('unexpected info: '..message) end,
    showOffline=function() error('unexpected offline') end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,
    openFile=function(self,path) self.opened=path end}
host:showBookMenu({book_id='42',title='Synthetic native book',author='Fixture',chapters={}})
local view=assert(host._book_detail_view);local action
for _,button in ipairs(view._action_buttons) do
    if button.text==require('weread.lib.plugin_util').tr('Read E-Ink chapter') then action=button end
end
assert(action and action.enabled~=false);action.callback()
wait(function() return host._native_direct_reading and host._native_direct_reading.menu end)
local menu=host._native_direct_reading.menu
assert(#menu.item_table==1 and menu.item_table[1].select_enabled)
assert(menu.subtitle==require('weread.lib.plugin_util').tr('Online: sync position or save selected highlights and private thoughts.'))
menu:onMenuSelect(menu.item_table[1])
wait(function() return host.opened~=nil end)
assert(not host._native_direct_reading and not host.busy_message)
print('WEREAD_DIRECT_UI='..json.encode{ok=true,path=host.opened})
