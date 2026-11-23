-- Read-only owner UI: credentials and source stay in pipes/tmpfs only.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local data=home
if input.plugin_home==true then
    data=home..'/weread';local lfs=require('libs/libkoreader-lfs');lfs.mkdir(data)
    assert(lfs.attributes(data,'mode')=='directory')
end
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=data,cache_dir=data,mock_endpoint=input.mock_endpoint,get=function(_,_,default) return default end,
    get_book=function() return nil end,get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
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
            and (url:find('chapters=0%2C'..input.uid..'&',1,true)
                or input.neighbor and url:find('chapters=0%2C'..input.neighbor.uid..'&',1,true))
            and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
    else
        assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
            and not headers.vid and not headers.accessToken and not headers.Cookie)
        if input.simulate_missing_images then return nil,404,{} end
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
local result,failure
local worker=require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=client,max_bytes=8*1024*1024,timeout=180}
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end,getChapters=function() return {} end},ui={},isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UIManager:show(self.busy_message)
    end,
    closeBusy=function(self) UIManager:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self) self.failed=true end,showOffline=function(self) self.failed=true end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function(self,path)
        self.opened=path
        if input.neighbor then self.ui.document={file=path};self._reader_session_gen=self._reader_session_gen+1 end
    end,
    onShowWeReadQuickMenu=require('weread.ui.reader_navigation').onShowWeReadQuickMenu,
    _native_direct_worker={cancel=function() worker:cancel() end,start=function(_,task,callback)
        return worker:start(task,function(value)
            if type(value)=='table' and value.source_sha256 then result=value end
            if type(value)=='table' and value.error then failure=value.error end
            callback(value)
        end)
    end}}
host:showBookMenu({book_id=input.book_id,title='Synthetic native book',author='Fixture',chapters={}})
local view=assert(host._book_detail_view);local action
for _,button in ipairs(view._action_buttons) do
    if button.text==require('weread.lib.plugin_util').tr('Read E-Ink chapter') then action=button end
end
assert(action and action.enabled~=false);action.callback()
wait(function() return host.failed or host._native_direct_reading and host._native_direct_reading.menu end)
assert(not host.failed)
local ctx=assert(host._native_direct_reading);local menu=assert(ctx.menu);local index
for i,row in ipairs(ctx.catalog.chapters) do if row.chapterUid==input.uid then assert(not index and row.downloadable);index=i end end
assert(index and menu.item_table[index].select_enabled)
assert(menu.subtitle==require('weread.lib.plugin_util').tr('Online: sync position or save selected highlights and private thoughts.'))
menu:onMenuSelect(menu.item_table[index])
wait(function() return host.failed or host.opened end)
if host.failed then
    local allowed={not_entitled=true,auth_expired=true,rate_limited=true,service_rejected=true,session_changed=true,
        catalog_changed=true,unavailable=true,invalid_source=true,invalid_image=true,remote_unsupported=true,storage=true}
    print('WEREAD_DIRECT_OWNER='..json.encode{ok=false,reason=allowed[failure] and failure or 'unavailable'});return
end
assert(not host.failed and result and result.source_sha256==input.source_sha256
    and result.book_version==input.book_version and not host._native_direct_reading and not host.busy_message)
local first_path,first_missing=host.opened,result.missing_images
local neighbor_path,neighbor_missing
if input.neighbor then
    host.opened=nil;result=nil
    assert(host:onShowWeReadQuickMenu())
    wait(function()
        local top=UIManager:getTopmostVisibleWidget()
        return host.failed or top and type(top.getButtonById)=='function' and top:getButtonById('next_chapter')~=nil
    end)
    assert(not host.failed)
    local next_action=assert(UIManager:getTopmostVisibleWidget():getButtonById('next_chapter'))
    assert(next_action.enabled~=false);next_action:onTapSelectButton()
    wait(function() return host.failed or host.opened end)
    assert(not host.failed and result and result.source_sha256==input.neighbor.source_sha256
        and result.book_version==input.book_version and host.opened~=first_path)
    neighbor_path,neighbor_missing=host.opened,result.missing_images
end
local count=assert(io.open(home..'/request-count','rb'));local requests=#assert(count:read('*a'));assert(count:close())
local report={ok=true,path=first_path,requests=requests,source_matches=true,missing_images=first_missing}
if input.neighbor then report.neighbor_path=neighbor_path;report.neighbor_missing_images=neighbor_missing;report.neighbor_source_matches=true end
print('WEREAD_DIRECT_OWNER='..json.encode(report))
