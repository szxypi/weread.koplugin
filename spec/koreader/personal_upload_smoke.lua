-- Full chooser, worker, COS transport and pending recovery; synthetic only.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'});G_reader_settings:saveSetting('language','zh_CN')
require('gettext').changeLang('zh_CN');package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=assert(tonumber(os.getenv('WEREAD_MOCK_PORT')))})
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local FM=require('apps/filemanager/filemanager');FM:showFiles(home);local plugin=assert(FM.instance.weread)
local login=require('weread.lib.qr_login'):new({},plugin.client,plugin.settings);login.login_cookies={wr_fp='1234567890'}
login:_complete_protocol({succeed=true,webLoginVid='900000',accessToken='mock-web-access'},login.generation)
local scope=assert(plugin.settings:get_auth_scope())
assert(require('weread.lib.native_credentials'):new(plugin.settings):save({vid=scope.vid,accessToken='mock-native-access',
    refreshToken='mock-native-refresh',deviceId='eink334691225'..string.rep('1',19)},scope,0,0))
local path=home..'/SyntheticUpload.txt';local content='Synthetic upload for KOReader.\n'
local f=assert(io.open(path,'wb'));assert(f:write(content));f:close()
local socket=require('socket');local function pump(test)
    local deadline=socket.gettime()+40
    repeat UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput();if test() then return end
        assert(socket.gettime()<deadline,'native upload deadline');socket.sleep(.01) until false
end
local Module=require('weread.ui.personal_upload');local Journal=require('weread.lib.personal_upload_journal')
local function close_info()
    local top=UI:getTopmostVisibleWidget();if top and top~=FM.instance and top.text then UI:close(top) end
end
local function choose()
    assert(Module.open(plugin));local chooser=assert(plugin._personal_upload_ui.chooser)
    chooser:onMenuHold({path=path});local picker=assert(chooser.button_dialog);picker.buttons[1][2].callback()
    pump(function() return plugin._personal_upload_ui and plugin._personal_upload_ui.dialog~=nil end)
    return assert(plugin._personal_upload_ui.dialog)
end
local text_path=path
path=home..'/SyntheticWarning.PDF';f=assert(io.open(path,'wb'));assert(f:write('%PDF-1.4 synthetic'));f:close()
local confirmation=choose()
assert(confirmation.text:find('微信读书转换 PDF 时可能改变排版或丢失图片。',1,true),'native PDF conversion warning missing')
UI:forceRePaint();Device.screen:shot(evidence..'/upload-pdf-warning.png');confirmation.cancel_callback()
assert(Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle','PDF warning cancel created pending upload')
os.remove(path);path=text_path
confirmation=choose();confirmation.cancel_callback()
assert(Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle','cancel created a pending upload')
confirmation=choose();UI:forceRePaint();Device.screen:shot(evidence..'/upload-confirm.png');confirmation.ok_callback()
pump(function() return not plugin._personal_upload_ui end)
local record=Journal:new(plugin.settings,plugin.client):read(scope)
assert(record and record.phase=='idle','confirmed upload left a pending record')
local status=assert(plugin.library_db:getShelfStatus('CB_uploadtest'))
assert(status.present==true,'uploaded book missing from saved cloud shelf')
f=assert(io.open(path,'rb'));assert(f:read('*a')==content);f:close();close_info()
local request=plugin.client.request
function plugin.client:request(options)
    local result={request(self,options)}
    if options.url:match('^https://i%.weread%.qq%.com/cos/notify%?') then return '{}',200,{} end
    return unpack(result)
end
confirmation=choose();confirmation.ok_callback();pump(function() return not plugin._personal_upload_ui end)
record=assert(Journal:new(plugin.settings,plugin.client):read(scope));assert(record.phase=='pending','unknown receipt was cleared')
close_info();assert(Module.open(plugin));local pending=assert(plugin._personal_upload_ui.dialog)
pending.buttons[2][1].callback();local clear=assert(plugin._personal_upload_ui.dialog)
UI:forceRePaint();Device.screen:shot(evidence..'/upload-pending.png');clear.ok_callback()
record=assert(Journal:new(plugin.settings,plugin.client):read(scope));assert(record.phase=='idle','explicit review did not clear pending intent')
close_info();f=assert(io.open(path,'rb'));assert(f:read('*a')==content);f:close()
plugin.client.request=request
path=home..'/SyntheticLarge.txt';content=string.rep('X',131073)
f=assert(io.open(path,'wb'));assert(f:write(content));f:close()
confirmation=choose();confirmation.ok_callback();local responsive=false
UI:scheduleIn(.05,function() responsive=plugin._personal_upload_ui~=nil end)
pump(function() return not plugin._personal_upload_ui end)
assert(responsive and Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle','large streaming upload blocked UI or stayed pending')
assert(plugin.library_db:getShelfStatus('CB_uploadlarge').present==true,'large uploaded book missing')
f=assert(io.open(path,'rb'));assert(f:read('*a')==content);f:close()
-- Upload a real synthetic PDF, then use the plugin book detail action to
-- open the unchanged local original without assigning a WeRead cloud identity.
close_info();path=home..'/SyntheticUpload.pdf';local pdf_body=assert(io.open(path,'rb'));content=pdf_body:read('*a');pdf_body:close()
confirmation=choose();confirmation.ok_callback();pump(function() return not plugin._personal_upload_ui end)
assert(Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle','PDF upload not settled')
local original=require('weread.lib.personal_original')
assert(original.resolve(plugin,'CB_uploadpdf')==path,'verified PDF upload did not persist its original association')
local reopened={settings=plugin.settings,library_db=require('weread.lib.library_db'):new(plugin.settings)}
assert(original.resolve(reopened,'CB_uploadpdf')==path,'new database instance lost local PDF association')
-- An older book can be explicitly linked; the confirmation explains that the
-- plugin cannot establish that the selected PDF matches the cloud book.
close_info();plugin:showBookMenu{book_id='CB_previous',title='合成旧书',chapters={}}
local previous=assert(plugin._book_detail_view);local choose_original
for _,row in ipairs(previous.data.actions or {}) do
    if row.text==require('weread.lib.i18n').tr('Choose or change local PDF') then choose_original=row end
end
assert(choose_original and not original.resolve(plugin,'CB_previous'),'old book unexpectedly linked')
local function manual_confirm()
    choose_original.callback();local selector=assert(plugin._personal_original_attach.chooser)
    selector:onMenuHold({path=path});assert(selector.button_dialog).buttons[1][2].callback()
    pump(function() return plugin._personal_original_attach and plugin._personal_original_attach.dialog end)
    return assert(plugin._personal_original_attach.dialog)
end
local manual=manual_confirm();assert(manual.text:find('无法核实',1,true) and manual.text:find('不会同步',1,true))
UI:forceRePaint();Device.screen:shot(evidence..'/original-pdf-manual-confirm.png');manual.cancel_callback()
assert(not original.resolve(plugin,'CB_previous'),'cancelled manual selection created a link')
manual=manual_confirm();manual.ok_callback()
assert(original.resolve(plugin,'CB_previous')==path,'confirmed manual selection was not saved')
local previous_record=assert(original.snapshot(plugin,'CB_previous'));local changed_record={path=path,identity={mode='file',dev=1,ino=1,size=1,modification=1,change=1}}
local record_key='personal_original_pdf:CB_previous'
assert(plugin.library_db:putProfileState(record_key,changed_record))
assert(not plugin.library_db:deleteProfileStateIf(record_key,previous_record),'stale confirmation deleted a replaced association')
assert(original.snapshot(plugin,'CB_previous').identity.ino==1 and plugin.library_db:putProfileState(record_key,previous_record))
close_info();local linked=assert(plugin._book_detail_view);local unlink
for _,row in ipairs(linked.data.actions or {}) do
    if row.text==require('weread.lib.i18n').tr('Remove local PDF association') then unlink=row end
end
assert(unlink);unlink.callback();local unlink_dialog=assert(plugin._personal_original_attach.dialog)
assert(unlink_dialog.text:find('原文件和云端书籍都会保留',1,true));unlink_dialog.cancel_callback()
assert(original.resolve(plugin,'CB_previous')==path,'cancelled unlink removed association')
unlink.callback();unlink_dialog=assert(plugin._personal_original_attach.dialog);unlink_dialog.ok_callback()
assert(not original.snapshot(plugin,'CB_previous') and original.resolve(plugin,'CB_uploadpdf')==path,'unlink affected another book association')
local kept=assert(io.open(path,'rb'));assert(kept:read('*a')==content,'unlink changed original PDF');kept:close()
close_info();plugin:closeWeReadUI();plugin:showBookMenu{book_id='CB_uploadpdf',title='合成 PDF',chapters={}}
local detail=assert(plugin._book_detail_view);local action
for _,row in ipairs(detail.data.actions or {}) do
    if row.text==require('weread.lib.i18n').tr('Read original PDF (local only, no cloud sync)') then action=row end
end
assert(action,'local original PDF action missing from book details')
UI:forceRePaint();Device.screen:shot(evidence..'/original-pdf-action.png');action.callback()
local Reader=require('apps/reader/readerui')
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==path end)
local reader=Reader.instance;local active=assert(reader.weread)
assert(not active:detectWeReadBook() and not active.progress_sync.current_book_id,'local original gained cloud sync identity')
local saved_cache=active.settings.cache_dir;active.settings.cache_dir=home
assert(not active:detectWeReadBook(),'local-only session acquired cloud identity after cache configuration changed')
active.settings.cache_dir=saved_cache
assert(reader.document:getPageCount()==2,'native PDF reader did not open both original pages')
UI:forceRePaint();Device.screen:shot(evidence..'/original-pdf-reader.png')
local after=assert(io.open(path,'rb'));assert(after:read('*a')==content,'opening the local PDF changed its bytes');after:close()
assert(os.rename(path,path..'.moved'));local replacement=assert(io.open(path,'wb'));replacement:write('different synthetic PDF');replacement:close()
assert(not original.resolve(reopened,'CB_uploadpdf'),'replaced local file retained an old association')
os.remove(path);assert(os.rename(path..'.moved',path))
print('PASS: native chooser, upload, explicit review and plugin original PDF reader without cloud binding')
