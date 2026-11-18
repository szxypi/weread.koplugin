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
plugin.settings:set('account',{});plugin.settings:set('cookies',{});plugin.settings:set('api_key','');plugin.settings:flush()
assert(not plugin.library_db:accountKey() and not plugin.settings:get_auth_scope())
plugin.isNetworkOnline=function() return true end
plugin.isNetworkConnected=function() return true end
plugin.fetchVisibleShelfCovers=function() end
local report=plugin.settings:get('read_report');report.enabled=false;plugin.settings:set('read_report',report)
local sync=plugin.settings:get('sync');sync.upload_on_close=false;plugin.settings:set('sync',sync);plugin.settings:flush()
local function pump(predicate)
    local deadline=socket.gettime()+60
    while not predicate() do
        assert(socket.gettime()<deadline,'guest QR reading deadline')
        UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
plugin:showBookstore();plugin.shelf_view.on_search()
local dialog=assert(plugin.shelf_view._shelf_popup)
dialog:setInputText('山谷来信');dialog.buttons[1][2].callback()
pump(function() return plugin.discovery_state and not plugin.discovery_loading end)
local book=assert(plugin.discovery_state.books[1]);assert(book.bookId=='900001' and plugin.discovery_state.source_kind=='public')
assert(plugin.shelf_view._item_rows[1]).callback()
pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
local detail=assert(plugin._book_detail_view);assert(plugin.settings:get_book('900001').detail_source=='public')
local read
for _,button in ipairs(detail._footer_actions) do
    if button.text==require('weread.lib.plugin_util').tr('▤ Read') then read=button end
end
assert(read);read.callback()
pump(function() return plugin.qr_login.qr_dialog and UI:getTopmostVisibleWidget()==plugin.qr_login.qr_dialog end)
local qr=plugin.qr_login.qr_dialog;qr:onTapClose()
assert(not plugin.qr_login.continuation and not plugin.settings:get_auth_scope() and not Reader.instance,
    'cancelled QR retained the reading continuation')
local body=require('json').encode{guest_login_pending=false}
local _,code=require('socket.http').request{url=plugin.settings.mock_endpoint..'/__control',proxy=plugin.settings.mock_endpoint,
    method='POST',headers={['content-type']='application/json',['content-length']=#body},
    source=require('ltn12').source.string(body),sink=require('ltn12').sink.null()}
assert(code==200)
assert(plugin._book_detail_view==detail);read.callback()
pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document:getPageCount()>1 end)
local reader=Reader.instance
assert(reader.weread:detectWeReadBook()=='900001' and reader.document.file:match('%.epub$'),
    'login did not resume the selected book in the native reader')
assert(not plugin._book_detail_view and not plugin.shelf_view and not plugin.book_reading_context,
    'login left old book views or reading work')
UI:forceRePaint();Device.screen:shot(evidence..'/guest-login-native-reader.png')
print('PASS: guest public search -> native details -> synthetic QR login -> selected book in native EPUB reader')
