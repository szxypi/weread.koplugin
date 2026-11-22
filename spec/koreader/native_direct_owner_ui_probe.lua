-- Read-only owner UI: credentials and source stay in pipes/tmpfs only.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,get=function(_,_,default) return default end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local original=Access.capture
Access.capture=function(s,existing) return original(s,existing or store) end
local client=require('weread.lib.client'):new(settings);local request=client.request
client.request=function(self,options)
    local url,headers=options.url,options.headers or {};local base='https://i.weread.qq.com'
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    if url==base..'/book/info?bookId='..input.book_id then assert(options.method=='GET')
    elseif url==base..'/book/chapterInfos' then
        assert(options.method=='POST');local body=json.decode(options.body)
        assert(#body.bookIds==1 and body.bookIds[1]==input.book_id and body.synckeys[1]==0
            and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
    elseif url:find(base..'/book/chapterdownload?',1,true)==1 then
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
            and url:find('chapters=0%2C'..input.uid..'&',1,true)
            and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
    else
        assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
            and not headers.vid and not headers.accessToken and not headers.Cookie)
    end
    if url:find(base,1,true)==1 then assert(headers.vid==input.credentials.vid and headers.accessToken==input.credentials.accessToken) end
    local count=assert(io.open(home..'/request-count','ab'));assert(count:write('1'));assert(count:close())
    return request(self,options)
end
local UIManager=require('ui/uimanager');local socket=require('socket')
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native direct owner UI timeout')
        UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
    end
end
local result
local worker=require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=client,max_bytes=8*1024*1024,timeout=180}
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end},ui={},isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UIManager:show(self.busy_message)
    end,
    closeBusy=function(self) UIManager:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self) self.failed=true end,showOffline=function(self) self.failed=true end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function(self,path) self.opened=path end,
    _native_direct_worker={cancel=function() worker:cancel() end,start=function(_,task,callback)
        return worker:start(task,function(value)
            if type(value)=='table' and value.source_sha256 then result=value end
            callback(value)
        end)
    end}}
host:showBookMenu({book_id=input.book_id,title='Synthetic native book',author='Fixture',chapters={}})
local view=assert(host._book_detail_view);local action
for _,button in ipairs(view._action_buttons) do
    if button.text==require('weread.lib.plugin_util').tr('Read E-Ink chapter (local only)') then action=button end
end
assert(action and action.enabled~=false);action.callback()
wait(function() return host.failed or host._native_direct_reading and host._native_direct_reading.menu end)
assert(not host.failed)
local ctx=assert(host._native_direct_reading);local menu=assert(ctx.menu);local index
for i,row in ipairs(ctx.catalog.chapters) do if row.chapterUid==input.uid then assert(not index and row.downloadable);index=i end end
assert(index and menu.item_table[index].select_enabled)
assert(menu.subtitle==require('weread.lib.plugin_util').tr('Reading position and notes do not sync to WeRead.'))
menu:onMenuSelect(menu.item_table[index])
wait(function() return host.failed or host.opened end)
assert(not host.failed and result and result.source_sha256==input.source_sha256
    and result.book_version==input.book_version and not host._native_direct_reading and not host.busy_message)
local count=assert(io.open(home..'/request-count','rb'));local requests=#assert(count:read('*a'));assert(count:close())
print('WEREAD_DIRECT_OWNER='..json.encode{ok=true,path=host.opened,requests=requests,source_matches=true,missing_images=result.missing_images})
