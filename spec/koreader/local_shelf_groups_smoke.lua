-- Real KOReader menus and SQLite against synthetic accounts, with no network.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local phase=assert(os.getenv('WEREAD_LOCAL_GROUP_PHASE'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'});require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket');local function pump(predicate)
    local deadline=socket.gettime()+30
    while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'local groups timeout') end
end
local FileManager=require('apps/filemanager/filemanager');FileManager:showFiles(home)
local host=assert(FileManager.instance.weread);local settings=host.settings
host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
host.client.request=function() error('unexpected local group network request') end
local function auth(id)
    settings:update_auth({account={user_vid=id,name='Synthetic'},cookies={wr_vid=id,wr_skey='synthetic-session'}},{replace_cookies=true})
end
auth('900000')
local shelf={{bookId='101',title='合成书一',author='作者'}, {bookId='102',title='合成书二',author='作者'},
             {bookId='103',title='合成书三',author='作者'}}
local cloud={{archiveId=7,name='云端测试组',bookIds={'101'}}}
if phase=='live' then assert(host.library_db:cacheShelf(shelf,cloud)) end
host:applyShelfSnapshot(shelf,cloud);host:showShelfView('books')
local function text(key) return require('weread.lib.i18n').tr(key) end
local function entry(menu,label)
    for _,row in ipairs(menu.item_table or {}) do if row.text==label then return row end end
    error('menu entry missing: '..label)
end
local function manage()
    local view=assert(host.shelf_view);view:showSourceMenu('books');local picker=assert(view._shelf_popup)
    picker:onMenuSelect(entry(picker,text('Manage local groups')))
    pump(function() return view._shelf_popup and view._shelf_popup~=picker end)
    return view,view._shelf_popup
end
local function select_row(view,menu,label)
    menu:onMenuSelect(entry(menu,label));pump(function() return view._shelf_popup and view._shelf_popup~=menu end)
    return view._shelf_popup
end
local function choose_group(view,menu,label)
    return select_row(view,menu,label)
end
local function group_action(view,dialog,index)
    dialog.buttons[index][1].callback();pump(function() return view._shelf_popup and view._shelf_popup~=dialog end)
    return view._shelf_popup
end
local function assert_shelf_cloud()
    local groups=host.shelf_groups;assert(groups[1] and groups[1].key=='archive:7' and #groups[1].books==1)
end
if phase=='live' then
    assert_shelf_cloud()
    local view,manager=manage();local input=select_row(view,manager,text('Create local group'))
    input:setInputText('本机测试');input.buttons[1][2].callback()
    pump(function() return host.shelf_view~=view end)
    assert(host.shelf_groups[#host.shelf_groups].key=='local:1')
    view,manager=manage();local actions=choose_group(view,manager,'本机测试');local picker=group_action(view,actions,1)
    picker:onMenuSelect(entry(picker,'合成书一'));picker:onMenuSelect(entry(picker,'合成书三'))
    UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_LOCAL_GROUP_EVIDENCE'))..'/choose-books.png')
    picker:onMenuSelect(entry(picker,text('Save local group books')));pump(function() return host.shelf_view~=view end)
    assert_shelf_cloud();local local_group=host.shelf_groups[#host.shelf_groups]
    assert(local_group.key=='local:1' and #local_group.books==2 and local_group.books[1].bookId=='101' and local_group.books[2].bookId=='103')
    view=manage();UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_LOCAL_GROUP_EVIDENCE'))..'/local-groups.png')
    require('weread.ui.shelf_popup').close(view)
    local partial={shelf[1],shelf[2]}
    host:applyShelfSnapshot(partial,cloud);host:showShelfView('books')
    assert(host.shelf_groups[#host.shelf_groups].incomplete)
    view,manager=manage();actions=choose_group(view,manager,'本机测试');picker=group_action(view,actions,1)
    picker:onMenuSelect(entry(picker,text('Save local group books')));pump(function() return host.shelf_view~=view end)
    local preserved=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(#preserved.groups[1].books==2 and preserved.groups[1].books[2]=='103','missing book was removed')
    host:applyShelfSnapshot(shelf,cloud);host:showShelfView('books')
    view=host.shelf_view;view:showSourceMenu('books');picker=assert(view._shelf_popup)
    picker:onMenuSelect(entry(picker,'本机 · 本机测试'));pump(function() return host.shelf_view~=view end)
    assert(host.shelf_view.group_key=='local:1' and #host.shelf_view.books==2)
    UI:forceRePaint()
    local state=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    local Model=require('weread.lib.local_shelf_groups');local changed=assert(Model.change(state,{kind='rename',id=1,name='并发新名称'}))
    assert(host.library_db:compareProfileState('shelf_local_groups_v1',state,changed))
    assert(not host.library_db:compareProfileState('shelf_local_groups_v1',state,state))
    assert(host.library_db:getProfileState('shelf_local_groups_v1').groups[1].name=='并发新名称')
    local conn=assert(host.library_db:open());conn:exec([[INSERT INTO profile_state (name,payload) VALUES ('synthetic_corrupt','broken')]]);conn:close()
    assert(not host.library_db:compareProfileState('synthetic_corrupt',nil,Model.empty()),'corrupt state was overwritten')
    host:applyShelfSnapshot(shelf,cloud);host:showShelfView('books')
    view,manager=manage();local stale_input=select_row(view,manager,text('Create local group'))
    stale_input:setInputText('不应保存')
    auth('900001');host:applyShelfSnapshot(shelf,cloud);stale_input.buttons[1][2].callback()
    assert(not host.library_db:getProfileState('shelf_local_groups_v1'),'old account dialog wrote to new account')
    assert(#host.shelf_groups==2,'foreign account inherited local group')
    require('weread.ui.shelf_popup').close(view)
    auth('900000');host:applyShelfSnapshot(shelf,cloud);assert(host.shelf_groups[#host.shelf_groups].label=='本机 · 并发新名称')
    -- Exercise paged management and book picking with a separate account.
    auth('900002')
    local many={};for i=1,40 do many[#many+1]={bookId=tostring(1000+i),title='合成第'..i..'本'} end
    local large=Model.empty();for i=1,15 do large=assert(Model.change(large,{kind='create',name='测试组'..i})) end
    assert(host.library_db:compareProfileState('shelf_local_groups_v1',nil,large))
    host:applyShelfSnapshot(many,{});host:showShelfView('books')
    view,manager=manage();assert(manager:getSize().h<=Device.screen:getHeight(),'group menu exceeds screen')
    assert(manager.items_per_page<#manager.item_table);manager:onNextPage()
    actions=choose_group(view,manager,'测试组15');picker=group_action(view,actions,1)
    assert(picker:getSize().h<=Device.screen:getHeight(),'book picker exceeds screen')
    assert(picker.items_per_page<#picker.item_table)
    local target=entry(picker,'合成第35本')
    local target_page=math.floor((36-1)/picker.items_per_page)+1
    while picker.page<target_page do picker:onNextPage() end
    picker:onMenuSelect(target)
    while picker.page>1 do picker:onPrevPage() end
    picker:onMenuSelect(entry(picker,text('Save local group books')))
    pump(function() return host.shelf_view~=view end)
    local paged=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(#paged.groups[15].books==1 and paged.groups[15].books[1]=='1035')
    auth('900000');host:applyShelfSnapshot(shelf,cloud)
    settings:flush()
else
    assert_shelf_cloud();assert(host.shelf_groups[#host.shelf_groups].label=='本机 · 并发新名称')
    local group=host.shelf_groups[#host.shelf_groups];assert(#group.books==2 and group.books[1].bookId=='101' and group.books[2].bookId=='103')
    local view,manager=manage();local actions=choose_group(view,manager,'并发新名称');local input=group_action(view,actions,2)
    input:setInputText('离线重命名');input.buttons[1][2].callback();pump(function() return host.shelf_view~=view end)
    assert(host.shelf_groups[#host.shelf_groups].label=='本机 · 离线重命名')
    view,manager=manage();actions=choose_group(view,manager,'离线重命名');local confirm=group_action(view,actions,3)
    confirm.ok_callback();pump(function() return host.shelf_view~=view end)
    assert_shelf_cloud();assert(#host.shelf_groups==2 and #host.shelf_regular==3)
    local state=assert(host.library_db:getProfileState('shelf_local_groups_v1'));assert(#state.groups==0 and state.next_id==2)
end
print('\nWEREAD_LOCAL_GROUPS='..require('json').encode({result='PASS',phase=phase,network_requests=0}))
os.exit(0)
