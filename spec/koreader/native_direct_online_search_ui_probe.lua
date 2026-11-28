-- Installed-plugin search against loopback services and local chapter copies.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new();settings.mock_endpoint=input.mock_endpoint
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid = input.credentials.vid,wr_skey='synthetic-web-access'})
local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
local cache=settings:get('cache');cache.show_annotations=false;cache.auto_prefetch_next_chapter=false;settings:set('cache',cache)
local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
local scope=assert(settings:get_auth_scope())
local chapters,paths=40,{}
if input.case=='offline_scan' then
    assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
    local Cache=require('weread.lib.native_direct_cache')
    local Crypto=require('weread.lib.crypto')
    local book={book_id='4242',title='Synthetic offline search',author='Fixture'}
    local digest=Crypto.sha256_hex('synthetic chapter list')
    local live=function() return settings:auth_scope_matches(scope) end
    for index=1,chapters do
        local uid=tostring(index)
        local xhtml='<html><body>'..string.rep('<p>Synthetic filler paragraph for the native reader.</p>',50)
            ..'<p>cobaltneedle of chapter '..uid..'</p></body></html>'
        local row={chapterUid=uid,chapterIdx=index,title='Synthetic chapter '..uid}
        local prepared={book_id=book.book_id,chapter_uid=uid,book_version=1,catalog_sha256=digest,
            reading_catalog_sha256=digest,source_sha256=Crypto.sha256_hex(xhtml),source_channel='eink',
            coordinate_source_authoritative=false,missing_images=0,xhtml=xhtml,css='',assets={}}
        paths[index]=assert(Cache.publish(settings,scope.vid,book,row,prepared,live)).path
    end
    input.path=paths[1]
else
    assert(require('weread.lib.native_credentials'):new(settings):save(input.credentials,scope,0,1))
end
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
assert(#loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function wait(predicate)
    local deadline=socket.gettime()+100
    while not predicate() do assert(socket.gettime()<deadline,'native online search timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread
if input.case=='offline_scan' then
    local function search()
        assert(host:onShowWeReadQuickMenu())
        wait(function()
            local top=UI:getTopmostVisibleWidget()
            return top and type(top.getButtonById)=='function' and top:getButtonById('search_cached')
        end)
        UI:getTopmostVisibleWidget():getButtonById('search_cached'):onTapSelectButton()
        wait(function() return host._native_direct_search and host._native_direct_search.input end)
        local owner=host._native_direct_search
        owner.input:setInputText('cobaltneedle');owner.input.buttons[1][2].callback()
        return owner
    end
    local before=socket.gettime()
    local owner=search()
    local workers,redraws,busy_redraws=1,0,0
    local start,switch=owner.worker.start,owner.menu.switchItemTable
    owner.worker.start=function(worker,...)
        workers=workers+1;return start(worker,...)
    end
    owner.menu.switchItemTable=function(menu,...)
        redraws=redraws+1
        if owner.job then busy_redraws=busy_redraws+1 end
        return switch(menu,...)
    end
    wait(function() return owner.finished and not owner.job end)
    local search_ms=math.floor((socket.gettime()-before)*1000+.5)
    assert(owner.checked==chapters and #owner.value==chapters and owner.unavailable==0)
    local original=owner.value
    owner.menu:onClose()
    owner=search()
    wait(function() return owner.checked>0 and owner.worker.job end)
    local checked=owner.checked
    assert(checked<chapters and #owner.value==checked)
    assert(host.busy_message):onTapClose()
    assert(not owner.job and not owner.finished and owner.checked==checked)
    local resume=owner.menu.item_table[1]
    assert(resume.text==require('weread.lib.plugin_util').tr('Continue searching downloaded chapters'))
    owner.menu:onMenuSelect(resume)
    wait(function() return owner.finished and not owner.job end)
    assert(owner.checked==chapters and #owner.value==chapters)
    for index,value in ipairs(owner.value) do
        assert(value.entry.chapter_uid==tostring(index) and value.hit.byte==original[index].hit.byte)
    end
    local selected=owner.value[chapters]
    for _,row in ipairs(owner.menu.item_table) do
        if row.text==selected.title..' · '..selected.hit.context then owner.menu:onMenuSelect(row);break end
    end
    wait(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==paths[chapters] end)
    local target=Reader.instance
    wait(function() return not target.weread._native_direct_search_incoming and not target.weread._native_direct_search_open end)
    local found=false
    for _,match in ipairs(assert(target.document:findAllText('cobaltneedle',false,0,64,false,0))) do
        if match.start and target.document:isXPointerInCurrentPage(match.start) then found=true;break end
    end
    assert(found)
    print('WEREAD_NATIVE_ONLINE_UI='..json.encode{ok=true,case=input.case,chapters=chapters,workers=workers,
        redraws=redraws,busy_redraws=busy_redraws,search_ms=search_ms,cancel_resume=true,last_hit_visible=true});return
end
local requests=0
local function configure(active)
    active.settings.mock_endpoint=input.mock_endpoint
    active.isNetworkOnline=function() return input.case~='offline' end;active.isNetworkConnected=active.isNetworkOnline
    active.showInfo=function(self,message) self.checked_message=message end
    local request=active.client.request
    active.client.request=function(self,options) requests=requests+1;return request(self,options) end
end
configure(host)
local original_open=host.openFile
host.openFile=function(self,path,callback,...)
    return original_open(self,path,function(next_reader) configure(assert(next_reader.weread));return callback(next_reader) end,...)
end
assert(host:onShowWeReadQuickMenu())
wait(function() local top=UI:getTopmostVisibleWidget();return top and type(top.getButtonById)=='function' and top:getButtonById('search_book') end)
local button=assert(UI:getTopmostVisibleWidget():getButtonById('search_book'));assert(button.enabled~=false);button:onTapSelectButton()
if input.case=='offline' then
    wait(function() return host._native_direct_search and host._native_direct_search.input end)
    local local_owner=host._native_direct_search;local_owner.input.buttons[1][1].callback()
    assert(not host._native_direct_search and Reader.instance==reader)
    print('WEREAD_NATIVE_ONLINE_UI='..json.encode{ok=true,case=input.case,offline_fallback=true});return
end
wait(function() return host._book_search_owner and host._book_search_owner.input end)
local owner=host._book_search_owner;owner.input:setInputText(input.keyword);owner.input.buttons[1][2].callback()
wait(function() return host.checked_message or owner.state and owner.state.finished and not owner.job end)
assert(not host.checked_message and #owner.value==1,'online result unavailable: '..tostring(host.checked_message)..' / '..#owner.value)
if input.case=='fallback' then
    local action
    for _,candidate in ipairs(owner.menu.item_table) do
        if candidate.text==require('weread.lib.plugin_util').tr('Search downloaded chapters') then action=candidate end
    end
    assert(action);local before=requests;owner.menu:onMenuSelect(action)
    wait(function() return host._native_direct_search and host._native_direct_search.input end)
    local local_owner=host._native_direct_search
    assert(local_owner.input:getInputText()==input.keyword and requests==before,'fallback lost query or used network')
    local_owner.input.buttons[1][1].callback()
    assert(not host._native_direct_search and Reader.instance==reader)
    print('WEREAD_NATIVE_ONLINE_UI='..json.encode{ok=true,case=input.case,offline_fallback=true});return
end
local target=owner.value[1];assert(target.chapter_uid==input.uid)
local item
for _,candidate in ipairs(owner.menu.item_table) do
    if candidate.select_enabled~=false and candidate.text:find(input.keyword,1,true) then item=candidate end
end
assert(item);owner.menu:onMenuSelect(item)
if input.case=='cancel' or input.case=='download' or input.case=='denied' then
    wait(function() return host.checked_message or owner.navigation and owner.navigation.confirm end)
    assert(not host.checked_message and owner.navigation and owner.navigation.confirm,'missing download confirmation')
    local confirm=owner.navigation.confirm
    if input.case=='cancel' then
        confirm.cancel_callback();assert(not owner.navigation and Reader.instance==reader)
        print('WEREAD_NATIVE_ONLINE_UI='..json.encode{ok=true,case=input.case,cancelled=true});return
    end
    confirm.ok_callback()
    if input.case=='denied' then
        wait(function() return host.checked_message~=nil end)
        assert(Reader.instance==reader and not owner.navigation)
        print('WEREAD_NATIVE_ONLINE_UI='..json.encode{ok=true,case=input.case,denied=true});return
    end
end
if input.case=='mismatch' then
    wait(function() return host.checked_message~=nil end)
    assert(Reader.instance==reader and not owner.navigation)
    print('WEREAD_NATIVE_ONLINE_UI='..json.encode{ok=true,case=input.case,blocked=true});return
end
local destination
if input.case=='same' then destination=reader
else wait(function() return Reader.instance and Reader.instance~=reader end);destination=Reader.instance end
local active=assert(destination.weread)
wait(function() return host.checked_message or active.checked_message
    or not active._native_online_search_incoming and not active._native_online_search_open and not owner.navigation end)
assert(not host.checked_message and not active.checked_message,'verified navigation failed')
local matches=assert(destination.document:findAllText(input.keyword,false,0,5,false,0));assert(#matches==1 and matches[1].start)
assert(destination.document:isXPointerInCurrentPage(matches[1].start),'search result opened the wrong page')
print('WEREAD_NATIVE_ONLINE_UI='..json.encode{ok=true,case=input.case,visible=true,cross=destination~=reader})
