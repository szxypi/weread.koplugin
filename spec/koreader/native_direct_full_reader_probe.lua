-- Actual installed plugin + ReaderUI, two isolated chapters, no network.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local Settings=require('weread.lib.settings');local settings=Settings:new()
assert(settings.data_dir==home..'/weread')
settings:set('account',{user_vid='12345678',name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid='12345678',wr_skey='synthetic'});settings:flush()
assert(settings:auth_scope_matches(settings:get_auth_scope()))
local PluginLoader=require('pluginloader')
PluginLoader.enabled_plugins,PluginLoader.disabled_plugins,PluginLoader.loaded_plugins={},{},{}
for _,entry in ipairs(PluginLoader:_discover()) do if entry.name=='weread' then PluginLoader:_load{entry} end end
assert(#PluginLoader.enabled_plugins==1,'candidate plugin was not loaded')
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function pump(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'installed reader navigation timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.first)
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local first=Reader.instance;local host=first.weread
assert(first.document.file==input.first and host.settings.data_dir==settings.data_dir)
assert(not host:detectWeReadBook() and not host._current_weread_book_id)
local report_id,_,reason=host.read_report:resolve_target();assert(not report_id and reason=='native_direct_local_only')
assert(first.document:getPageCount()>2 and first.rolling)
first.rolling:onGotoPage(2);UI:forceRePaint();local anchor=assert(first.document:getXPointer())
-- Exercise the installed plugin's reconnect reminder without allowing any
-- network request or account write. The position entry is still resolved by
-- the actual cache worker before the separately tested position flow starts.
local old_sync=host.settings:get('sync',{})
host.settings:set('sync',{pull_on_open=true})
local online=true
host.isNetworkConnected=function() return online end
host.isNetworkOnline=function() return online end
local reconnect=require('weread.ui.native_direct_reconnect')
assert(reconnect.ready(host),'native reconnect tracking did not start')
local position=require('weread.ui.native_direct_position');local old_start=position.start;local selected
position.start=function(_,entry,options) selected={entry=entry,options=options};return true end
for index,action in ipairs({'cloud','upload'}) do
    online=false;host:onNetworkDisconnected()
    first.rolling:onGotoPage(index==1 and 3 or 2);host:onPageUpdate()
    online=true;host:onNetworkConnected()
    pump(function() return host._native_direct_reconnect and host._native_direct_reconnect.dialog end)
    local dialog=host._native_direct_reconnect.dialog
    UI:forceRePaint();assert(dialog:getContentSize().h<=Device.screen:getHeight(),'reconnect prompt exceeded screen')
    local button=assert(dialog:getButtonById('reconnect_'..action));button:onTapSelectButton()
    pump(function() return selected~=nil end)
    assert(selected.entry.book_id=='42' and selected.entry.chapter_uid=='37' and selected.options[action]==true,
        'reconnect choice did not reach verified native chapter')
    selected=nil
end
position.start=old_start;host.settings:set('sync',old_sync)
first.rolling:onGotoPage(2);UI:forceRePaint();assert(first.document:isXPointerInCurrentPage(anchor))
-- Search the real cached EPUB without network and independently resolve the
-- result in CREngine. Search coordinates remain local, not upload authority.
local cache=require('weread.lib.native_direct_cache')
local current=function() return Reader.instance==first and first.document.file==input.first end
local entry=assert(cache.identify(host.settings,'12345678',input.first,current))
local found=require('weread.lib.native_direct_search').scan(host.settings,'12345678',entry,'paragraph 50',1,false,current)
assert(found.complete and #found.hits==1 and found.hits[1].chapter_uid==entry.chapter_uid)
local identity=require('weread.lib.book_file_identity').read_document(first.document,entry.book_id)
local index=assert(require('weread.lib.source_dom').open_direct_prepared(first.document,entry.book_id,entry.chapter_uid,
    identity,{is_current=current}))
local point=assert(index:locate_anchor(found.hits[1].anchor))
assert(point.file_id==entry.file_id and point.chapter_uid==entry.chapter_uid and point.xpointer)
assert(first.document:isXPointerInCurrentPage(anchor),'search moved the page')
local function quick(active,id)
    assert(active:onShowWeReadQuickMenu())
    pump(function()
        local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById(id)~=nil
    end)
    UI:forceRePaint();local button=assert(UI:getTopmostVisibleWidget():getButtonById(id))
    assert(button.enabled~=false);button:onTapSelectButton()
end
quick(host,'reader_progress')
pump(function() return host._weread_reader_progress~=nil end)
local progress=assert(host._weread_reader_progress)
UI:forceRePaint()
local util=require('weread.lib.plugin_util')
assert(progress.dialog.title:find(util.tr('Current chapter file'),1,true)
    and progress.dialog.title:find(util.T(util.tr('Chapter %1 / %2'),'1','3'),1,true),
    'native chapter progress was mislabeled')
assert(progress.whole_estimate and math.abs(progress.whole_estimate-progress.snapshot.percent/3)<1e-7,
    'saved native catalog did not provide the correct estimate')
assert(progress.dialog:getContentSize().h<=Device.screen:getHeight(),'native progress panel exceeded the screen')
assert(progress.dialog:getButtonById('progress_previous_chapter').enabled==false)
local next_button=assert(progress.dialog:getButtonById('progress_next_chapter'))
assert(next_button.enabled~=false);next_button:onTapSelectButton()
pump(function() return Reader.instance and Reader.instance~=first and Reader.instance.document.file==input.second end)
local second=Reader.instance;host=assert(second.weread)
assert(not host:detectWeReadBook() and not host._current_weread_book_id)
do
    local perpage=G_reader_settings:readSetting('items_per_page')
    local font_size=G_reader_settings:readSetting('items_font_size')
    local connected=host.isNetworkConnected
    local access=require('weread.lib.native_read_access')
    local capture=access.capture
    local second_point=assert(second.document:getXPointer())
    G_reader_settings:saveSetting('items_per_page',1)
    G_reader_settings:saveSetting('items_font_size',20)
    -- The saved-only route must not depend on the network status or E-Ink grant.
    host.isNetworkConnected=function() return true end
    access.capture=function() error('saved-only chapter list read the online grant') end
    quick(host,'saved_chapters')
    pump(function()
        return host._native_direct_reading and host._native_direct_reading.menu
    end)
    local ctx=host._native_direct_reading
    local menu=ctx.menu
    local prefix=util.tr('Current chapter')..' · '
    assert(ctx.offline and menu.page==2 and menu.item_table[2].text:find(prefix,1,true)==1
        and not menu.item_table[1].text:find(prefix,1,true) and second.document.file==input.second,
        'offline reader did not open the catalog at its current chapter file')
    menu:onLeftButtonTap()
    local input_dialog=assert(menu._shelf_popup)
    input_dialog:setInputText('no matching synthetic chapter')
    input_dialog.buttons[1][2].callback()
    assert(menu.page==1 and not menu.item_table[1].select_enabled)
    menu:onLeftButtonTap()
    assert(menu._shelf_popup).buttons[1][1].callback()
    assert(menu.page==2 and menu.item_table[2].text:find(prefix,1,true)==1,
        'clearing offline chapter search did not return to the current chapter')
    menu:onClose()
    assert(not host._book_detail_view and not host._native_direct_reading and not host.busy_message
        and UI:getTopmostVisibleWidget()==second and second.document:isXPointerInCurrentPage(second_point),
        'closing the offline catalog did not return directly to the same reading page')
    host.isNetworkConnected=function() return false end
    quick(host,'chapter_list')
    pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
    ctx=host._native_direct_reading
    assert(ctx.offline and ctx.menu.page==2 and ctx.menu.item_table[2].text:find(prefix,1,true)==1,
        'the regular chapter list no longer opens the saved catalog offline')
    ctx.menu:onClose()
    access.capture=capture
    host.isNetworkConnected=connected
    G_reader_settings:saveSetting('items_per_page',perpage)
    G_reader_settings:saveSetting('items_font_size',font_size)
end
quick(host,'reader_progress')
pump(function() return host._weread_reader_progress~=nil end)
progress=assert(host._weread_reader_progress)
assert(progress.whole_estimate and math.abs(progress.whole_estimate-(100+progress.snapshot.percent)/3)<1e-7,
    'second chapter estimate did not follow catalog weights')
UI:close(progress.dialog)
local db=assert(host.library_db:open())
db:exec("UPDATE native_direct_catalog_estimate SET payload='corrupt'");db:close()
quick(host,'reader_progress')
pump(function() return host._weread_reader_progress~=nil end)
progress=assert(host._weread_reader_progress)
assert(not progress.whole_estimate and progress.dialog.title:find(util.tr('Whole-book estimate unavailable.'),1,true),
    'corrupt catalog was used for a progress estimate')
local previous=assert(progress.dialog:getButtonById('progress_previous_chapter'))
assert(previous.enabled~=false);previous:onTapSelectButton()
pump(function() return Reader.instance and Reader.instance~=second and Reader.instance.document.file==input.first
    and Reader.instance.weread and (Reader.instance.weread._reader_session_gen or 0)>0 end)
local reopened=Reader.instance;host=assert(reopened.weread);UI:forceRePaint()
assert(reopened.document:isXPointerInCurrentPage(anchor),'local page was not restored after chapter return')
assert(not host:detectWeReadBook() and not host._current_weread_book_id)
G_reader_settings:saveSetting('end_document_action','next_file')
assert(host:handleEndOfBook({}))
pump(function() return Reader.instance and Reader.instance~=reopened and Reader.instance.document.file==input.second end)
local before_search=Reader.instance;host=assert(before_search.weread)
assert(not host:detectWeReadBook())
do
    local current_point=assert(before_search.document:getXPointer())
    local is_connected=host.isNetworkConnected
    host.isNetworkConnected=function() return false end
    local function cancel_saved_fallback()
        pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
        local ctx=host._native_direct_reading
        assert(Reader.instance==before_search and before_search.document:getXPointer()==current_point
            and ctx.offline and #ctx.menu.item_table==2 and ctx.menu.subtitle==util.tr('Chapter unavailable offline'),
            'missing next chapter did not preserve the open native reader')
        ctx.menu:onClose()
        assert(not host._native_direct_reading and not host.busy_message and UI:getTopmostVisibleWidget()==before_search)
    end
    quick(host,'reader_progress')
    pump(function() return host._weread_reader_progress~=nil end)
    local next_saved=assert(host._weread_reader_progress.dialog:getButtonById('progress_next_chapter'))
    UI:forceRePaint();assert(next_saved.enabled~=false);next_saved:onTapSelectButton()
    cancel_saved_fallback()
    assert(host:handleEndOfBook({}))
    cancel_saved_fallback()
    host.isNetworkConnected=is_connected
end
quick(host,'search_cached')
pump(function() return host._native_direct_search and host._native_direct_search.input end)
local owner=host._native_direct_search
owner.input:setInputText('paragraph 50');owner.input.buttons[1][2].callback()
pump(function() return owner.finished and not owner.job end)
assert(owner.checked==2 and owner.unavailable==0 and #owner.value==2,'saved chapters were not searched')
local wanted
for _,value in ipairs(owner.value) do if value.entry.chapter_uid=='37' then wanted=value end end
assert(wanted)
local item
for _,row in ipairs(owner.menu.item_table) do
    if row.text==wanted.title..' · '..wanted.hit.context then item=row end
end
assert(item,'search result missing from reader menu');owner.menu:onMenuSelect(item)
pump(function() return Reader.instance and Reader.instance~=before_search and Reader.instance.document.file==input.first end)
local searched=Reader.instance;local search_host=assert(searched.weread)
pump(function() return not search_host._native_direct_search_incoming and not search_host._native_direct_search_open end)
local check=function() return Reader.instance==searched and searched.document.file==input.first end
local verified_entry=assert(cache.identify(search_host.settings,'12345678',input.first,check))
local verified_identity=require('weread.lib.book_file_identity').read_document(searched.document,verified_entry.book_id)
local verified_index=assert(require('weread.lib.source_dom').open_direct_prepared(searched.document,verified_entry.book_id,
    verified_entry.chapter_uid,verified_identity,{is_current=check}))
local target=assert(verified_index:locate_anchor(wanted.hit.anchor))
assert(searched.document:isXPointerInCurrentPage(target.xpointer),'cross-chapter search opened the wrong page')
quick(search_host,'search_cached')
pump(function() return search_host._native_direct_search and search_host._native_direct_search.input end)
local cancelled=search_host._native_direct_search
cancelled.input:setInputText('paragraph');cancelled.input.buttons[1][2].callback()
searched.rolling:onGotoPage(1)
pump(function() return not search_host._native_direct_search end)
assert(Reader.instance==searched and searched.document.file==input.first,'search cancellation changed chapter')
quick(search_host,'search_cached')
pump(function() return search_host._native_direct_search and search_host._native_direct_search.input end)
local same=search_host._native_direct_search
same.input:setInputText('paragraph 80');same.input.buttons[1][2].callback()
pump(function() return same.finished and not same.job end)
local same_hit
for _,value in ipairs(same.value) do if value.entry.chapter_uid=='37' then same_hit=value end end
assert(same_hit)
local same_item
for _,row in ipairs(same.menu.item_table) do
    if row.text==same_hit.title..' · '..same_hit.hit.context then same_item=row end
end
assert(same_item);same.menu:onMenuSelect(same_item)
pump(function() return not search_host._native_direct_search_open end)
assert(Reader.instance==searched,'same-chapter result reopened the file')
local same_point=assert(verified_index:locate_anchor(same_hit.hit.anchor))
assert(searched.document:isXPointerInCurrentPage(same_point.xpointer),'same-chapter search opened the wrong page')
print('WEREAD_DIRECT_FULL_READER='..json.encode{ok=true,network_blocked=true,plugin_loaded=true,roundtrip=true,
    native_page_restored=true,end_of_book=true,web_coordinates=false,offline_search=true,search_cancel=true,same_chapter=true})
