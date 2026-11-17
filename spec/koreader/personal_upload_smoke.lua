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
local confirmation=choose();confirmation.cancel_callback()
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
plugin:closeWeReadUI();print('PASS: native chooser, upload, unknown receipt and explicit review')
