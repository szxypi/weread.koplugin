-- Three isolated ReaderUI processes share only their synthetic local profile.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
local owner_test=os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1'
assert(os.getenv('WEREAD_SYNTHETIC')=='1' or owner_test)
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
if owner_test then assert(home:match('^/dev/shm/')) end
package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local Settings=require('weread.lib.settings');local settings=Settings:new()
if not owner_test then
    settings:set('account',{user_vid='12345678',name='Synthetic',login_method='qr'})
    settings:set('cookies',{wr_vid='12345678',wr_skey='synthetic'})
else
    local scope=settings:get_auth_scope()
    assert(scope and scope.vid==input.vid and settings:auth_scope_matches(scope))
end
local manual=input.stage=='manual_offline' or input.stage=='manual_restore' or input.stage=='manual_discard'
    or input.stage=='manual_conflict' or input.stage=='conflict_cancel_close' or input.stage=='reopen_replace'
local sync=settings:get('sync',{});sync.pull_on_open=not manual;sync.upload_on_close=false;sync.upload_interval_minutes=0
settings:set('sync',sync);settings:flush()
local Common=require('weread.ui.common')
Common.isNetworkConnected=function() return input.stage~='save' and not manual end;Common.isNetworkOnline=Common.isNetworkConnected
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
Reader:showReader(assert(input.first or input.path))
pump(function()
    local reader=Reader.instance;local host=reader and reader.weread
    return host and host._native_direct_reconnect and host._native_direct_reconnect.entry
end)
local reader=Reader.instance;local host=reader.weread;local owner=host._native_direct_reconnect
local store=require('weread.lib.native_direct_pending');local scope=host.settings:get_auth_scope()
local function read() return store.read(host.library_db,host.settings,scope,owner.entry,function() return true end) end
local function estimate()
    local _,values=host.library_db:getShelfProgress({owner.entry.book_id},true)
    return values and values[owner.entry.book_id]
end
if input.stage=='save' then
    for _,size in ipairs({48,72,96}) do
        if reader.document:getPageCount()>=3 then break end
        assert(reader.font:onSetFontSize(size));UI:forceRePaint()
    end
    assert(reader.document:getPageCount()>=3,'chapter does not cover multiple pages')
    reader.rolling:onGotoPage(1);host:onPageUpdate();owner.baseline=require('weread.lib.source_context').location(reader.document,'page')
    reader.rolling:onGotoPage(3);host:onPageUpdate()
    assert(owner.offline and owner.dirty,'offline turn was not detected')
    local anchor=assert(require('weread.lib.source_context').location(reader.document,'page')).xpointer
    local expected=3/reader.document:getPageCount()*100/3
    local entry=owner.entry;reader:onClose(false);assert(not Reader.instance)
    local value=assert(store.read(host.library_db,host.settings,scope,entry,function() return true end))
    assert(value.xpointer==anchor,'close did not preserve the offline position')
    local cache=require('weread.lib.native_direct_cache')
    local rows=assert(cache.list(host.settings,scope.vid,entry.book_id,function() return true end))
    assert(store.mark(host.library_db,host.settings,scope,entry.book_id,rows,function() return true end))
    local found=false
    for _,row in ipairs(rows) do if row.key==entry.key and row.copy==entry.copy then found=row.pending_offline==true end end
    assert(found,'saved chapter did not show its pending-position hint')
    if not owner_test then
        local saved=assert(estimate(),'verified offline page did not save a whole-book estimate')
        assert(math.abs(saved-expected)<1e-7,'offline estimate did not match the saved page and catalog weights')
        local FM=require('apps/filemanager/filemanager')
        if not FM.instance then FM:showFiles(home) end
        local browser=assert(FM.instance.weread)
        local id=entry.book_id
        assert(browser.library_db:cacheShelf({{bookId=id,title='Synthetic',readUpdateTime=os.time(),finishReading=0}},{}))
        assert(browser.library_db:putShelfProgress({{book_id=id,percent=91,exact_percent=91,fetched_at=os.time()}}))
        local label='≈'..math.floor(expected)..'%'
        local function check_view()
            local view=assert(browser.shelf_view)
            local cell=assert(view._item_rows[1]);local book=cell.book
            assert(book.bookId==id and book._shelf_progress==91 and book._shelf_progress_exact==91,
                'displayed estimate changed the cached cloud or filter value')
            local text=view.cover_mode and cell._progress_badge_text or view:itemStatus(book)
            assert(text and text:find(label,1,true),'native estimate was not labeled on the device view')
        end
        browser:showHome();check_view()
        browser:showBookshelf(false);check_view()
        browser.shelf_view.on_display_change('view_mode','list');check_view()
        browser:closeWeReadUI()
    end
elseif manual then
    local record=assert(read())
    if input.stage=='manual_conflict' or input.stage=='conflict_cancel_close' then reader.rolling:onGotoPage(1);host:onPageUpdate() end
    if input.stage=='manual_restore' or input.stage=='reopen_replace' then
        assert(not reader.document:isXPointerInCurrentPage(record.xpointer),'manual restore did not start on another page')
    elseif input.stage=='manual_conflict' or input.stage=='conflict_cancel_close' then
        assert(not reader.document:isXPointerInCurrentPage(record.xpointer) and owner.dirty,'offline conflict was not established')
    else assert(reader.document:isXPointerInCurrentPage(record.xpointer),'offline chapter did not reopen at its saved page') end
    assert(host:onShowWeReadQuickMenu())
    pump(function()
        local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById('native_offline_reminder')~=nil
    end)
    local quick=UI:getTopmostVisibleWidget()
    UI:forceRePaint();assert(quick:getContentSize().h<=Device.screen:getHeight(),'quick menu exceeded the screen')
    assert(quick:getButtonById('native_offline_reminder')):onTapSelectButton()
    pump(function() return owner.dialog~=nil end)
    if input.stage=='manual_conflict' or input.stage=='conflict_cancel_close' then
        assert(owner.dialog.ok_callback and owner.dialog.cancel_callback,'offline conflict did not request confirmation')
        owner.dialog:onClose();assert(read().xpointer==record.xpointer and owner.conflict,'cancel changed the prior reminder')
        assert(require('weread.ui.native_direct_reconnect').checkpoint(host)==false,'cancelled conflict was overwritten')
        if input.stage=='conflict_cancel_close' then
            reader:onClose(false);assert(read().xpointer==record.xpointer,'closing replaced the cancelled reminder')
            print('WEREAD_DIRECT_PENDING_READER='..json.encode{ok=true,stage=input.stage,network_blocked=true})
            os.exit(0)
        end
        assert(host:onShowWeReadQuickMenu())
        pump(function()
            local top=UI:getTopmostVisibleWidget()
            return top and type(top.getButtonById)=='function' and top:getButtonById('native_offline_reminder')~=nil
        end)
        assert(UI:getTopmostVisibleWidget():getButtonById('native_offline_reminder')):onTapSelectButton()
        pump(function() return owner.dialog and owner.dialog.ok_callback end)
        owner.dialog.ok_callback()
        pump(function() return owner.dialog and owner.dialog.getButtonById and owner.dialog:getButtonById('reconnect_later') end)
        local updated=assert(read());assert(updated.xpointer~=record.xpointer and reader.document:isXPointerInCurrentPage(updated.xpointer),
            'confirmed conflict did not save the current page')
        record=updated
    end
    if input.stage=='reopen_replace' then
        UI:forceRePaint();assert(owner.dialog:getContentSize().h<=Device.screen:getHeight(),'replacement menu exceeded the screen')
        assert(owner.dialog:getButtonById('reconnect_replace')):onTapSelectButton()
        assert(owner.dialog and owner.dialog.ok_callback,'replacement did not request confirmation')
        owner.dialog:onClose();assert(read().xpointer==record.xpointer,'cancelling replacement changed the reminder')
        assert(host:onShowWeReadQuickMenu())
        pump(function()
            local top=UI:getTopmostVisibleWidget()
            return top and type(top.getButtonById)=='function' and top:getButtonById('native_offline_reminder')~=nil
        end)
        assert(UI:getTopmostVisibleWidget():getButtonById('native_offline_reminder')):onTapSelectButton()
        pump(function() return owner.dialog and owner.dialog.getButtonById and owner.dialog:getButtonById('reconnect_replace') end)
        owner.dialog:getButtonById('reconnect_replace'):onTapSelectButton()
        assert(owner.dialog and owner.dialog.ok_callback);owner.dialog.ok_callback()
        pump(function() return owner.dialog and owner.dialog.getButtonById and owner.dialog:getButtonById('reconnect_later') end)
        local updated=assert(read());assert(updated.xpointer~=record.xpointer and reader.document:isXPointerInCurrentPage(updated.xpointer),
            'confirmed replacement did not preserve the reopened current page')
        record=updated
    end
    if input.stage=='manual_restore' then
        assert(owner.dialog:getButtonById('reconnect_restore')):onTapSelectButton()
        pump(function() return owner.dialog and owner.dialog:getButtonById('reconnect_later') end)
        assert(reader.document:isXPointerInCurrentPage(record.xpointer),'manual offline restore missed the saved page')
    end
    assert(not owner.dialog:getButtonById('reconnect_cloud') and not owner.dialog:getButtonById('reconnect_upload'),
        'offline manual reminder offered cloud actions')
    assert(owner.dialog:getButtonById('reconnect_discard') and owner.dialog:getButtonById('reconnect_later'),
        'offline manual reminder omitted local choices')
    if input.stage=='manual_discard' then
        owner.dialog:getButtonById('reconnect_discard'):onTapSelectButton()
        assert(owner.dialog and owner.dialog.ok_callback,'offline discard skipped confirmation')
        owner.dialog.ok_callback();assert(not read() and not estimate(),'offline confirmation did not remove the reminder and estimate')
        assert(reader.document:isXPointerInCurrentPage(record.xpointer),'offline removal moved the page')
        reader:onClose(false);assert(not read(),'closing recreated a removed offline reminder')
    else
        owner.dialog:getButtonById('reconnect_later'):onTapSelectButton();assert(read(),'manual review removed the reminder')
        reader:onClose(false)
    end
elseif input.stage=='discard_cancel' then
    pump(function() return owner.record and owner.dialog end)
    local button=assert(owner.dialog:getButtonById('reconnect_discard'));button:onTapSelectButton()
    assert(owner.dialog and owner.dialog.cancel_callback,'discard did not request confirmation')
    owner.dialog:onClose();assert(read(),'cancelling discarded the reminder')
    reader:onClose(false)
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
    reader.rolling:onGotoPage(1);host:onPageUpdate();assert(read(),'moving after restore removed the reminder')
    reader:onClose(false)
elseif input.stage=='discard' then
    pump(function() return owner.record and owner.dialog end)
    local record=assert(read());assert(reader.document:isXPointerInCurrentPage(record.xpointer),'local page was not restored')
    UI:forceRePaint();assert(owner.dialog:getContentSize().h<=Device.screen:getHeight(),'reminder menu exceeded the screen')
    local button=assert(owner.dialog:getButtonById('reconnect_discard'));button:onTapSelectButton()
    assert(owner.dialog and owner.dialog.ok_callback,'discard did not request confirmation')
    owner.dialog.ok_callback();assert(not read(),'confirmed removal did not clear the reminder')
    assert(reader.document:isXPointerInCurrentPage(record.xpointer),'removing the reminder moved the page')
    reader:onClose(false)
elseif input.stage=='cleared' then
    assert(not read() and not owner.record and not estimate(),'a removed reminder returned after restart')
    reader:onClose(false)
else error('unknown stage') end
print('WEREAD_DIRECT_PENDING_READER='..json.encode{ok=true,stage=input.stage,network_blocked=true})
