-- Disposable, network-blocked ReaderUI processes share an isolated profile.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local settings=require('weread.lib.settings'):new();local scope=assert(settings:get_auth_scope())
assert(scope.vid==input.vid and settings:auth_scope_matches(scope))
settings:set('offline_time',{enabled=true,auto_native=false});settings:flush()
local sync=settings:get('sync',{});sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0
settings:set('sync',sync);settings:flush()
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' or entry.name=='statistics' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==2)
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function pump(predicate,phase)
    local deadline=socket.gettime()+60
    while not predicate() do
        if socket.gettime()>=deadline then
            local host=Reader.instance and Reader.instance.weread
            local state=host and host.offline_time and host.offline_time.state or 'none'
            if ({none=true,disabled=true,reader_hidden=true,native_time_checking=true,native_time_unavailable=true,
                recording_native=true,statistics_unavailable=true,paused=true,no_book=true,error=true})[state] then
                print('WEREAD_DIRECT_TIME_DIAGNOSTIC='..phase..'_'..state)
            end
            error('capture timed out')
        end
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(assert(input.path))
pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.statistics end,'reader')
local reader=Reader.instance;local host=reader.weread;local stats=reader.statistics
assert(stats:isEnabledAndNotFrozen() and stats.id_curr_book,'statistics unavailable')
while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
assert(UI:getTopmostVisibleWidget()==reader,'reader is not visible')
host.isNetworkConnected=function() return false end
local collector=host.offline_time;local account=host.library_db:accountKey()
if input.stage=='capture' then
    assert(collector:start());pump(function() return collector.active~=nil end,'collector')
    local before=collector:status().pending;local started=collector.active.last_seen
    socket.sleep(6);assert(collector:update('timer'))
    assert(collector:status().pending-before==collector.active.last_seen-started and collector.active.last_seen-started>=5,
        'reading duration missing or duplicated')
    assert(collector:stop('paused'))
elseif input.stage~='reopen' and input.stage~='reopen_review' then error('invalid stage') end
local rows=assert(collector.store:pending(account));assert(#rows>0,'captured duration missing')
local count=0;local total=0;local selection
for _,row in ipairs(rows) do
    assert(row.book_id==input.book_id and row.version_source=='native_direct' and #row.file_id==64,'wrong duration identity')
    count=count+1;total=total+row.duration
    selection={book_id=row.book_id,file_id=row.file_id,book_version=row.book_version}
end
assert(total>=5 and selection,'captured duration too short')
local cursor,prior=1,nil;local found
repeat
    found=require('weread.lib.native_direct_readtime_source').scan_page(host.settings,account,scope,selection,cursor,prior,function()
        return Reader.instance==reader and host.settings:auth_scope_matches(scope)
    end)
    if found.kind=='more' then cursor,prior=found.cursor,found.prior end
until found.kind~='more'
assert(found.kind=='found','duration source missing')
local entry=assert(require('weread.lib.native_direct_cache').identify(host.settings,scope.vid,found.reference.file,function() return true end))
assert(entry.file_id==selection.file_id and entry.source_sha256==found.reference.source_sha256,'wrong chapter source')
local snapshot=require('weread.lib.readtime_transfer_contract').digest(rows)
if input.stage=='reopen_review' then
    assert(collector:stop('paused'))
    local selected=assert(require('weread.lib.readtime_transfer_queue'):new{
        ledger=collector.store,coverage=host.readtime_coverage}:select(account,input.book_id,{current_day=true,allow_native=true}))
    assert(selected.selection and selected.selection.current_day and selected.selection.native_direct
        and selected.selection.seconds==total and selected.selection.file_id==selection.file_id,
        'current-day selection omitted the captured time')
    host.isNetworkConnected=function() return true end
    local sent
    host.offline_time_transfer_service={cancel=function() end,start=function(_self,mode,owner,batch,references,guard,callback)
        sent={mode=mode,owner=owner,batch=batch,references=references,guard=guard,callback=callback};return true
    end}
    host:showOfflineTimeStatus();pump(function() return host._offline_time_menu~=nil end,'menu')
    local tr=require('weread.lib.i18n').tr;local action
    for _,item in ipairs(host._offline_time_menu.item_table) do
        if item.text==tr('Check today’s E-Ink chapter time') then action=item end
    end
    assert(action,'current-day time action missing');action.callback()
    pump(function() return host._offline_time_detail~=nil end,'detail')
    local submit
    for _,row in ipairs(host._offline_time_detail.buttons) do for _,button in ipairs(row) do
        if button.text==tr('Transfer this batch') then submit=button end
    end end
    assert(submit,'transfer action missing');submit.callback();pump(function() return sent~=nil end,'source')
    assert(sent.mode=='send' and sent.owner==account and sent.guard()
        and require('weread.lib.readtime_transfer_contract').digest(sent.batch)
            ==require('weread.lib.readtime_transfer_contract').digest(selected.selection),
        'menu prepared a different time batch')
    assert(#sent.references==1 and sent.references[1].kind=='native_direct'
        and sent.references[1].file==found.reference.file
        and sent.references[1].source_sha256==found.reference.source_sha256,'menu selected a different source')
    if input.expect_no_position then
        assert(sent.references[1].file==reader.document.file,'selected source is not the open file')
        sent.callback({kind='position_required'})
        local dialog=assert(host._offline_time_detail);local quick_action
        for _,row in ipairs(dialog.buttons) do for _,button in ipairs(row) do
            if button.text==tr('Open reading quick menu') then quick_action=button end
        end end
        assert(quick_action,'first-position quick menu action missing');quick_action.callback()
        pump(function()
            local top=UI:getTopmostVisibleWidget()
            return top and type(top.getButtonById)=='function' and top:getButtonById('native_upload_position')~=nil
        end,'quick')
        assert(not host._offline_time_review,'time review remained open')
        UI:close(UI:getTopmostVisibleWidget())
    else
        sent.callback({kind='unavailable'});host:closeOfflineTimeUI()
    end
    host.offline_time_transfer_service=nil
    assert(require('weread.lib.readtime_transfer_contract').digest(assert(collector.store:pending(account)))==snapshot,
        'blocked preparation changed the ledger')
end
reader:onClose(false)
print('WEREAD_DIRECT_TIME_OWNER='..json.encode{ok=true,stage=input.stage,network_blocked=true,rows=count,seconds=total,
    snapshot=snapshot,review_verified=input.stage=='reopen_review',
    guidance_verified=input.stage=='reopen_review' and input.expect_no_position==true})
