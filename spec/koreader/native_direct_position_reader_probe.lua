-- Installed plugin + ReaderUI position check against a local synthetic service.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new();assert(settings.data_dir==home..'/weread')
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid = input.credentials.vid,wr_skey='synthetic-web-access'});settings:flush()
local scope=assert(settings:get_auth_scope());assert(settings:auth_scope_matches(scope))
assert(require('weread.lib.native_credentials'):new(settings):save(input.credentials,scope,0,1))
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
assert(#loader.enabled_plugins==1)
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native position UI timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.path)
wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread;local destination_host
local function configure(active)
active.settings.mock_endpoint=input.mock_endpoint
active.isNetworkConnected=function() return true end
local requests=active.client.request
active.client.request=function(self,options)
    local url=options.url;assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
    assert(url=='https://i.weread.qq.com/book/info?bookId=42'
        or url=='https://i.weread.qq.com/book/getProgress?bookId=42'
        or input.mode:find('^preview') and url=='https://i.weread.qq.com/shelf/sync'
        or url=='https://i.weread.qq.com/book/chapterInfos'
        or url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1
        or url=='https://weread.qq.com/api/userInfo?userVid=12345678'
        or url=='https://weread.qq.com/web/book/chapterInfos'
        or input.mode:find('^preview') and url:find('https://weread.qq.com/web/book/getProgress?',1,true)==1
        or url:find('https://weread.qq.com/web/reader/',1,true)==1
        or url:find('https://weread.qq.com/web/book/chapter/e_',1,true)==1)
    if url:find('https://weread.qq.com/web/',1,true)==1 then
        assert(options.headers.Cookie:find('synthetic-refreshed-cookie',1,true),'account cookie rotation was not used')
    end
    return requests(self,options)
end
active.showInfo=function(self,message) self.checked_message=message end
end
configure(host)
local open_file=host.openFile
host.openFile=function(self,path,callback,...)
    return open_file(self,path,function(next_reader)
        destination_host=assert(next_reader.weread);configure(destination_host)
        return callback(next_reader)
    end,...)
end
local native_worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=65536,timeout=180}
local captured,point
host._native_direct_position_worker={cancel=function() native_worker:cancel() end,start=function(_,task,callback)
    local ctx=assert(host._native_direct_position);captured={text=ctx.input.text,offset=ctx.input.point_offset}
    if input.mode:find('^preview') then
        task=function()
            local value,why=require('weread.lib.native_direct_upload_preview').prepare(host.client,host.settings,ctx.entry,
                ctx.file,ctx.input,ctx.native,ctx.web,function() return true end)
            if value then
                assert(value.dispatch_authorized==false and value.desired.summary and value.desired.raw_percent==50)
                return {position=value.position}
            end
            return {error=why}
        end
    end
    return native_worker:start(task,function(value) point=value.position or value.comparison and value.comparison.position;callback(value) end)
end}
local function open_menu()
    local id=(input.mode:find('^cloud') or input.mode:find('^cross_')) and 'native_cloud_position' or 'native_position_check'
    assert(host:onShowWeReadQuickMenu())
    wait(function()
        local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById(id)~=nil
    end)
    UI:forceRePaint();assert(UI:getTopmostVisibleWidget():getButtonById(id)):onTapSelectButton()
end
open_menu()
if input.mode=='move' or input.mode=='cloud_move' then
    wait(function() return native_worker.job~=nil end)
    assert(reader.rolling and reader.document:getPageCount()>2);reader.rolling:onGotoPage(2);UI:forceRePaint()
    wait(function() return native_worker.job==nil end)
    assert(not host.checked_message and not host._native_direct_position,'changed page accepted a stale result')
elseif input.mode=='cloud' or input.mode=='cloud_cancel' or input.mode=='cloud_after' then
    wait(function() return host.checked_message~=nil or host._native_direct_position and host._native_direct_position.confirm end)
    assert(not host.checked_message and host._native_direct_position and host._native_direct_position.confirm)
    local before=reader.document:getCurrentPage();local confirm=host._native_direct_position.confirm
    if input.mode=='cloud_cancel' then
        confirm.cancel_callback();assert(not host._native_direct_position and reader.document:getCurrentPage()==before)
    elseif input.mode=='cloud_after' then
        confirm.ok_callback();wait(function() return host.checked_message~=nil end)
        assert(host.checked_message==require('weread.lib.plugin_util').tr('The cloud position changed during the check. Your current page is kept.'))
        assert(reader.document:getCurrentPage()==before and not host._native_direct_position)
    else
        confirm.ok_callback();wait(function() return host.checked_message~=nil end)
        assert(host.checked_message==require('weread.lib.plugin_util').tr('Opened the cloud reading position in this chapter.'))
        assert(reader.document:getCurrentPage()~=before and not host._native_direct_position)
    end
elseif input.mode=='cloud_other' or input.mode:find('^cross_') then
    wait(function() return host.checked_message~=nil or host._native_direct_position and host._native_direct_position.confirm end)
    assert(not host.checked_message and host._native_direct_position and host._native_direct_position.confirm)
    local confirm=host._native_direct_position.confirm
    if input.mode=='cloud_other' then
        confirm.cancel_callback();assert(not host._native_direct_position and Reader.instance==reader)
    else
        confirm.ok_callback()
        if input.mode=='cross_changed' or input.mode=='cross_denied' or input.mode=='cross_unlocatable' then
            wait(function() return host.checked_message~=nil end)
            local expected=input.mode=='cross_changed' and 'The cloud position changed during the check. Your current page is kept.'
                or input.mode=='cross_denied' and 'The cloud chapter is not available to this account.'
                or 'The cloud position could not be located in the target chapter. Your current page is kept.'
            assert(host.checked_message==require('weread.lib.plugin_util').tr(expected) and Reader.instance==reader)
        elseif input.mode=='cross_after_switch' then
            wait(function() return destination_host and destination_host.checked_message~=nil end)
            assert(Reader.instance~=reader and Reader.instance.weread==destination_host
                and destination_host.checked_message==require('weread.lib.plugin_util').tr('The cloud position changed during the check. Your current page is kept.'))
            assert(Reader.instance.document:getCurrentPage()<=2)
        else
            wait(function() return destination_host and destination_host.checked_message~=nil end)
            assert(Reader.instance~=reader and Reader.instance.weread==destination_host
                and destination_host.checked_message==require('weread.lib.plugin_util').tr('Opened the cloud reading position in this chapter.'))
            assert(Reader.instance.document.file~=input.path and Reader.instance.document:getCurrentPage()>2)
            local matches=assert(Reader.instance.document:findAllText('Target paragraph 0100',false,0,3,false,0))
            assert(#matches==1 and matches[1].start and Reader.instance.document:isXPointerInCurrentPage(matches[1].start),
                'the independently identified cloud target is not on the opened page')
            if input.mode=='cross_cached' then assert(Reader.instance.document.file==input.second) end
        end
    end
else
    wait(function() return host.checked_message~=nil end)
    local tr=require('weread.lib.plugin_util').tr
    if input.mode=='mismatch' then
        assert(host.checked_message==tr('The chapter source changed, so the reading position could not be checked.') and not point)
    elseif input.mode=='cloud_changed' then
        assert(host.checked_message==tr('The cloud position changed during the check. Your current page is kept.') and not point)
    elseif input.mode=='cloud_empty' then
        assert(host.checked_message==tr('There is no cloud reading position yet. Your current page is kept.'))
    elseif input.mode=='preview_changed' or input.mode=='preview_web_changed' then
        assert(host.checked_message==tr('The cloud position changed during the check. Your current page is kept.') and not point)
    elseif input.mode=='preview_missing' then
        assert(host.checked_message==tr('Could not check this reading position.') and not point)
    else
        assert(host.checked_message==tr('The local reading position was checked against the chapter source. Cloud sync is not enabled yet.'))
        assert(point and point.upload_verified==false and point.source_current and point.basis=='filtered_xhtml_utf16')
    end
end
print('WEREAD_POSITION_READER='..json.encode{ok=true,mode=input.mode,text=captured and captured.text or '',
    point_offset=captured and captured.offset or 0,offset=point and point.chapter_offset or -1})
