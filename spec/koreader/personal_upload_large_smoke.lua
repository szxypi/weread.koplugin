-- Packaged UI upload of a streamed synthetic file larger than the old limit.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'});G_reader_settings:saveSetting('language','zh_CN')
require('gettext').changeLang('zh_CN');package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=assert(tonumber(os.getenv('WEREAD_MOCK_PORT')))})
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local FM=require('apps/filemanager/filemanager');FM:showFiles(home);local plugin=assert(FM.instance.weread)
local login=require('weread.lib.qr_login'):new({},plugin.client,plugin.settings);login.login_cookies={wr_fp='1234567890'}
login:_complete_protocol({succeed=true,webLoginVid='900000',accessToken='mock-web-access'},login.generation)
local scope=assert(plugin.settings:get_auth_scope())
assert(require('weread.lib.native_credentials'):new(plugin.settings):save({vid=scope.vid,accessToken='mock-native-access',
    refreshToken='mock-native-refresh',deviceId='eink334691225'..string.rep('1',19)},scope,0,0))
local path=home..'/SyntheticBig.txt';local block=string.rep('L',65536)
local file=assert(io.open(path,'wb'));for _i=1,144 do assert(file:write(block)) end;assert(file:write('L'));file:close()
local socket=require('socket');local function pump(test)
    local deadline=socket.gettime()+100
    repeat UI:setInputTimeout(0);UI:handleInput();if test() then return end
        assert(socket.gettime()<deadline,'large upload deadline');socket.sleep(.01) until false
end
local tr=require('weread.lib.plugin_util').tr;local found=false
for _i,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Upload local book') then item.callback();found=true;break end end
assert(found);local chooser=assert(plugin._personal_upload_ui.chooser)
chooser:onMenuHold({path=path});local picker=assert(chooser.button_dialog);picker.buttons[1][2].callback()
pump(function() return plugin._personal_upload_ui and plugin._personal_upload_ui.dialog end)
assert(plugin._personal_upload_ui.dialog).ok_callback()
local responsive=false;UI:scheduleIn(.1,function() responsive=plugin._personal_upload_ui~=nil end)
pump(function() return not plugin._personal_upload_ui end)
assert(responsive and plugin.personal_upload_worker.timeout==1800,'large upload blocked UI or used short deadline')
assert(require('weread.lib.personal_upload_journal'):new(plugin.settings,plugin.client):read(scope).phase=='idle')
assert(plugin.library_db:getShelfStatus('CB_uploadBig').present==true)
file=assert(io.open(path,'rb'));for _i=1,144 do assert(file:read(65536)==block) end
assert(file:read(1)=='L' and file:read(1)==nil);file:close()
plugin:closeWeReadUI();print('PASS: streamed 9 MiB synthetic native upload, original unchanged')
