-- Real native widgets, QR login protocol and ReaderUI against a synthetic server.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=assert(tonumber(os.getenv('WEREAD_MOCK_PORT')))})
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket')
local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
FM:showFiles(home);local plugin=assert(FM.instance.weread)
local reopen=os.getenv('WEREAD_READING_REOPEN')=='1'
local rank=os.getenv('WEREAD_GUEST_RANK')=='1'
local hold=os.getenv('WEREAD_GUEST_HOLD')=='1'
local function pump(predicate)
    local deadline=socket.gettime()+60
    while not predicate() do
        assert(socket.gettime()<deadline,'guest QR reading deadline')
        UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
if reopen then
    plugin.isNetworkOnline=function() return false end
    plugin.isNetworkConnected=function() return false end
    plugin.fetchVisibleShelfCovers=function() end
    local input=assert(io.open(evidence..'/guest-reading-checkpoint.json','rb'))
    local expected=require('json').decode(input:read('*a'));input:close()
    assert(plugin.library_db:accountKey() and plugin.settings:get_auth_scope(),'saved login missing after reopening')
    plugin:showHome()
    local selected
    for _,book in ipairs(plugin.shelf_view.books) do
        if tostring(book.bookId or book.book_id)==expected.book_id then selected=book end
    end
    assert(selected and selected._cached,'recent book is unavailable offline')
    if expected.title then assert(selected.title==expected.title,'offline recent book lost its public title') end
    plugin.shelf_view.on_select(selected)
    pump(function() return Reader.instance and Reader.instance.document.file==expected.path end)
    local reader=Reader.instance
    assert(reader.weread:detectWeReadBook()==expected.book_id
        and reader.document:isXPointerInCurrentPage(expected.xpointer),'offline reopen lost book or native page')
    UI:forceRePaint();Device.screen:shot(evidence..'/guest-login-offline-reopen.png')
    print('PASS: fresh offline process -> recent book -> native reader at saved page')
    os.exit(0)
end
plugin.settings:set('account',{});plugin.settings:set('cookies',{});plugin.settings:set('api_key','');plugin.settings:flush()
assert(not plugin.library_db:accountKey() and not plugin.settings:get_auth_scope())
plugin.isNetworkOnline=function() return true end
plugin.isNetworkConnected=function() return true end
plugin.fetchVisibleShelfCovers=function() end
local report=plugin.settings:get('read_report');report.enabled=false;plugin.settings:set('read_report',report)
local sync=plugin.settings:get('sync');sync.upload_on_close=false;sync.pull_on_open=false
plugin.settings:set('sync',sync);plugin.settings:flush()
if rank then
    plugin:showHome()
    local entry
    for _,button in ipairs(plugin.shelf_view._navigation_buttons) do
        if button.text==require('weread.lib.plugin_util').tr('Bookstore') then entry=button end
    end
    assert(entry);entry.callback()
else
    plugin:showBookstore();plugin.shelf_view.on_search()
    local dialog=assert(plugin.shelf_view._shelf_popup)
    dialog:setInputText('山谷来信');dialog.buttons[1][2].callback()
end
pump(function() return plugin.discovery_state and not plugin.discovery_loading end)
local book=assert(plugin.discovery_state.books[1]);assert(book.bookId=='900001' and plugin.discovery_state.source_kind=='public')
if rank then assert(plugin.discovery_state.kind=='category' and plugin.discovery_state.category_id=='rising') end
local detail,read
local function choose_read()
    if hold then
        local cell=assert(plugin.shelf_view._item_rows[1])
        UI:forceRePaint()
        local event=require('ui/event')
        local pos=require('ui/geometry'):new{x=cell.dimen.x+math.floor(cell.dimen.w/2),y=cell.dimen.y+math.floor(cell.dimen.h/2)}
        assert(cell:handleEvent(event:new('Gesture',{ges='hold',pos=pos})))
        local dialog=assert(plugin.shelf_view._shelf_popup)
        assert(cell:handleEvent(event:new('Gesture',{ges='hold_release',pos=pos})))
        for _,row in ipairs(dialog.buttons) do for _,button in ipairs(row) do
            if button.text==require('weread.lib.plugin_util').tr('Read now') then button.callback();return end
        end end
        error('guest book hold missing Read now')
    end
    read.callback()
end
if not hold then
    assert(plugin.shelf_view._item_rows[1]).callback()
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    detail=assert(plugin._book_detail_view);assert(plugin.settings:get_book('900001').detail_source=='public')
    for _,button in ipairs(detail._footer_actions) do
        if button.text==require('weread.lib.plugin_util').tr('▤ Read') then read=button end
    end
    assert(read)
end
choose_read()
pump(function() return plugin.qr_login.qr_dialog and UI:getTopmostVisibleWidget()==plugin.qr_login.qr_dialog end)
local qr=plugin.qr_login.qr_dialog;qr:onTapClose()
assert(not plugin.qr_login.continuation and not plugin.settings:get_auth_scope() and not Reader.instance,
    'cancelled QR retained the reading continuation')
local body=require('json').encode{guest_login_pending=false}
local _,code=require('socket.http').request{url=plugin.settings.mock_endpoint..'/__control',proxy=plugin.settings.mock_endpoint,
    method='POST',headers={['content-type']='application/json',['content-length']=#body},
    source=require('ltn12').source.string(body),sink=require('ltn12').sink.null()}
assert(code==200)
assert(hold or plugin._book_detail_view==detail);choose_read()
pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document:getPageCount()>1 end)
local reader=Reader.instance
assert(reader.weread:detectWeReadBook()=='900001' and reader.document.file:match('%.epub$'),
    'login did not resume the selected book in the native reader')
assert(not plugin._book_detail_view and not plugin.shelf_view and not plugin.book_reading_context,
    'login left old book views or reading work')
reader.rolling:onGotoPage(2)
UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
local checkpoint={book_id='900001',path=reader.document.file,xpointer=reader.document:getXPointer(),title=hold and book.title or nil}
reader.weread:onFlushSettings();reader:onClose(false)
local output=assert(io.open(evidence..'/guest-reading-checkpoint.json','wb'))
assert(output:write(require('json').encode(checkpoint)));output:close()
print('PASS: guest public entry -> native '..(hold and 'hold' or 'details')..' -> synthetic QR login -> selected native book and page')
