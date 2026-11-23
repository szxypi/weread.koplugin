-- Installed plugin, real ReaderUI switch and account-scoped synthetic notes.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new()
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid = input.credentials.vid,wr_skey = 'synthetic-web-access'});settings:flush()
local scope=assert(settings:get_auth_scope());local store=require('weread.lib.native_credentials'):new(settings)
local saved,revision=store:read();if not saved then assert(store:save(input.credentials,scope,revision or 0,1)) end
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
assert(#loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function wait(predicate)
    local deadline=socket.gettime()+80
    while not predicate() do assert(socket.gettime()<deadline,'cross note timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
local Display=require('weread.ui.personal_marks');local attach=Display.attach
Display.attach=function(host)
    host.settings.mock_endpoint=input.mock_endpoint
    host.isNetworkConnected=function() return not input.offline end
    host.isNetworkOnline=function() return not input.offline end
    local request=host.client.request
    host.client.request=function(self,options)
        assert(not input.offline,'offline cross note requested network')
        assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
        return request(self,options)
    end
    local show=host.showInfo
    host.showInfo=function(self,message) host.test_message=message;return show(self,message) end
    return attach(host)
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local first=Reader.instance;local host=first.weread
first.rolling:onGotoPage(3);UI:forceRePaint()
local before=first.document:getCurrentPage()
local choices={mark={'My cloud highlights','cross-mark','open_highlight'},
    thought={'My cloud thoughts','cross-thought','open_thought_quote'},
    bookmark={'My cloud bookmarks','cross-bookmark','open_bookmark'}}
local selected=assert(choices[input.kind]);local action;local tr=require('weread.lib.plugin_util').tr
for _,item in ipairs(host:getMainMenuItems()) do if item.text==tr(selected[1]) then action=item.callback end end
assert(action);action();wait(function() return host._my_marks_owner~=nil or host.test_message~=nil end)
assert(not host.test_message,'opening cloud list failed')
local owner=host._my_marks_owner;local row
for _,item in ipairs(owner.menu.item_table) do if item.my_note_id==selected[2] then row=item end end
assert(row,'cross chapter note missing');row.callback();UI:forceRePaint()
local popup=assert(owner.menu._shelf_popup)
assert(popup.button_table:getButtonById(selected[3])):onTapSelectButton()
wait(function() return Reader.instance~=first or host.test_message~=nil end)
if input.expect_failure then
    assert(host.test_message and Reader.instance==first and first.document:getCurrentPage()==before,
        'damaged target changed the original reader')
    print('WEREAD_CROSS_NOTE='..json.encode{ok=true,kind=input.kind,offline=input.offline==true,failed_safely=true})
    return
end
assert(not host.test_message,'cross chapter preparation failed: '..tostring(host.test_message))
wait(function()
    local reader=Reader.instance
    if not reader or not reader.document or not reader.weread then return false end
    local matches=reader.document:findAllText('Target paragraph 0100',false,0,3,false,0)
    return matches and #matches==1 and reader.document:isXPointerInCurrentPage(matches[1].start)
        or reader.weread.test_message~=nil
end)
local second=Reader.instance;assert(not second.weread.test_message,'cross chapter position failed')
assert(second~=first and second.document.file~=input.path and second.document:getCurrentPage()>2)
print('WEREAD_CROSS_NOTE='..json.encode{ok=true,kind=input.kind,offline=input.offline==true})
