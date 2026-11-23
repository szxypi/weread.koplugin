-- Installed plugin, real ReaderUI/statistics and isolated offline chapters.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new()
settings:set('account',{user_vid='12345678',name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid='12345678',wr_skey='synthetic'});settings:flush()
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' or entry.name=='statistics' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==2,'plugin or native statistics missing')
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function pump(predicate)
    local deadline=socket.gettime()+60
    while not predicate() do
        assert(socket.gettime()<deadline,'offline time probe timed out')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.first)
pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.statistics end)
local reader=Reader.instance;local host=reader.weread;local stats=reader.statistics
assert(stats:isEnabledAndNotFrozen() and stats.id_curr_book,'statistics not ready')
assert(not host:detectWeReadBook())
host.isNetworkConnected=function() return false end
host.settings:set('offline_time',{enabled=true});host.settings:flush()
local collector=host.offline_time
assert(collector:start());pump(function() return collector.active~=nil end)
local started=collector.active.last_seen
socket.sleep(6)
assert(collector:update('timer'))
local total=collector:status().pending
assert(total>=5 and total==collector.active.last_seen-started,'actual offline dwell was not captured')
local endpoint=collector.active.last_seen
assert(collector:update('timer'))
assert(collector:status().pending-total==collector.active.last_seen-endpoint,'duplicate capture')
reader:handleEvent(require('ui/event'):new('ReadingPaused'))
assert(not collector.active and not collector.task,'pause did not seal capture')
local paused=collector:status().pending;socket.sleep(2)
assert(collector:status().pending==paused,'pause was included')
reader:handleEvent(require('ui/event'):new('ReadingResumed'))
pump(function() return collector.active~=nil end)
started=collector.active.last_seen;socket.sleep(6);assert(collector:update('timer'))
assert(collector:status().pending-paused==collector.active.last_seen-started,'resume replayed old time')
assert(collector:stop('paused'))
local first_total=collector:status().pending
host:openFile(input.second)
pump(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==input.second end)
reader=Reader.instance;host=assert(reader.weread);host.isNetworkConnected=function() return false end
collector=host.offline_time;assert(collector:start());pump(function() return collector.active~=nil end)
started=collector.active.last_seen;socket.sleep(6);assert(collector:update('timer'))
assert(collector:status().pending-first_total==collector.active.last_seen-started,'chapter transition lost or duplicated time')
assert(collector:stop('paused'))
local account=host.library_db:accountKey();local rows=assert(collector.store:pending(account))
assert(#rows>0)
local C=require('weread.lib.readtime_transfer_contract')
local files={};local selections={}
for _,row in ipairs(rows) do
    assert(row.book_id=='42' and row.version_source=='native_direct' and #row.file_id==64)
    assert(not C.verified(row,os.time()),'ordinary transfer selected native chapter time')
    files[row.file_id]=true
    selections[row.file_id]={book_id=row.book_id,file_id=row.file_id,book_version=row.book_version}
end
local count=0;for _ in pairs(files) do count=count+1 end;assert(count==2,'chapter sources were not kept distinct')
local scope=assert(host.settings:get_auth_scope())
for _,selection in pairs(selections) do
    local cursor,prior=1,nil;local result
    repeat
        result=require('weread.lib.native_direct_readtime_source').scan_page(host.settings,account,scope,selection,cursor,prior,function()
            return Reader.instance==reader and host.settings:auth_scope_matches(scope)
        end)
        if result.kind=='more' then cursor,prior=result.cursor,result.prior end
    until result.kind~='more'
    assert(result.kind=='found','native chapter ledger source was not found: '..result.kind)
    local checked=assert(require('weread.lib.native_direct_cache').identify(host.settings,scope.vid,result.reference.file,function() return true end))
    assert(checked.file_id==selection.file_id and checked.source_sha256==result.reference.source_sha256)
end
-- Exercise the installed menu and its real subprocess source scan with a
-- separate synthetic historical ledger. The transport is an in-memory spy.
local actual_store,actual_coverage=collector.store,host.readtime_coverage
local isolated=home..'/time-ui-fixture';assert(require('libs/libkoreader-lfs').mkdir(isolated))
local Ledger=require('weread.lib.offline_time_store');local Coverage=require('weread.lib.readtime_coverage')
local old=os.time()-2*86400;local ui_ledger=Ledger:new(isolated);local ui_coverage=Coverage:new(isolated,function() return old-100 end)
assert(ui_coverage:initialize())
local first_row=rows[1]
local window=assert(ui_ledger:begin(account,{book_id='42',stats_book=1,start_time=old,time_zone='+08:00',
    book_version=first_row.book_version,file_id=first_row.file_id,version_source='native_direct'}))
assert(ui_ledger:collect(account,window,{{page='1',start_time=old,duration=5}},old+5,true))
collector.store=ui_ledger;host.readtime_coverage=ui_coverage
local sent
host.offline_time_transfer_service={cancel=function() end,start=function(_self,mode,owner,selection,references,guard,callback)
    sent={mode=mode,owner=owner,selection=selection,references=references,guard=guard,callback=callback};return true
end}
host.isNetworkConnected=function() return true end
host:showOfflineTimeStatus();pump(function() return host._offline_time_menu~=nil end)
local tr=require('weread.lib.i18n').tr
local item
for _,row in ipairs(host._offline_time_menu.item_table) do if row.text==tr('Check saved time') then item=row end end
assert(item,'saved time action missing');item.callback()
pump(function() return host._offline_time_detail~=nil end)
local submit
for _,row in ipairs(host._offline_time_detail.buttons) do for _,button in ipairs(row) do
    if button.text==tr('Transfer this batch') then submit=button end
end end
assert(submit,'native historical batch was not offered');submit.callback()
pump(function() return sent~=nil end)
assert(sent.mode=='send' and sent.owner==account and sent.selection.native_direct==true and sent.guard())
local reference=sent.references[1]
assert(reference and reference.kind=='native_direct' and reference.file and reference.chapter_uid)
local saved=assert(require('weread.lib.native_direct_cache').identify(host.settings,scope.vid,reference.file,function() return true end))
assert(saved.file_id==first_row.file_id,'UI sent a different chapter source')
sent.callback({kind='unavailable'});host:closeOfflineTimeUI();host.offline_time_transfer_service=nil
collector.store,host.readtime_coverage=actual_store,actual_coverage
host.isNetworkConnected=function() return false end
local previous=collector:status().pending
host.settings:set('account',{user_vid='87654321',name='Other',login_method='qr'})
host.settings:set('cookies',{wr_vid='87654321',wr_skey='synthetic'});host.settings:flush()
host:onWeReadAccountChanged()
pump(function() return host._native_offline_time and host._native_offline_time.state=='unavailable' end)
assert(not collector.active and collector:status().pending==0,'foreign account recorded or saw previous time')
assert(collector.store:summary(account).pending==previous,'old account records changed')
print('WEREAD_DIRECT_OFFLINE_TIME='..json.encode{ok=true,network_blocked=true,real_statistics=true,
    pause_resume=true,deduplicated=true,chapter_change=true,source_discovery=true,source_ui=true,
    account_isolated=true,ordinary_path_isolated=true})
