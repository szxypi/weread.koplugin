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
    settings:update_auth({account={user_vid=id,name='Synthetic'},cookies={wr_vid = id,wr_skey='synthetic-session'}},{replace_cookies=true})
end
auth('900000')
local shelf={{bookId='101',title='合成书一',author='作者'}, {bookId='102',title='合成书二',author='作者'},
             {bookId='103',title='合成书三',author='Writer Three'}}
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
local function button(dialog,label)
    for _,row in ipairs(dialog.buttons or {}) do for _,item in ipairs(row) do if item.text==label then return item end end end
    error('button missing: '..label)
end
local function quick_groups(book)
    local view=assert(host.shelf_view);view.on_hold(book,'books');local dialog=assert(view._shelf_popup)
    assert(dialog:getSize().h<=Device.screen:getHeight(),'book actions exceed the screen')
    button(dialog,text('Local groups for this book')).callback()
    pump(function() return view._shelf_popup and view._shelf_popup~=dialog end)
    return view,view._shelf_popup
end
local function assert_shelf_cloud()
    local groups=host.shelf_groups;assert(groups[1] and groups[1].key=='archive:7' and #groups[1].books==1)
end
if phase=='live' then
    assert_shelf_cloud()
    local LocalGroups=require('weread.ui.local_shelf_groups')
    assert(not LocalGroups.available(host,{bookId='999'}),'off-shelf book was offered local grouping')
    assert(not LocalGroups.available(host,{bookId='101',book_id='102'}),'conflicting book identity was offered local grouping')
    local view,manager=manage();local input=select_row(view,manager,text('Create local group'))
    input:setInputText('本机测试');input.buttons[1][2].callback()
    pump(function() return host.shelf_view~=view end)
    assert(host.shelf_groups[#host.shelf_groups].key=='local:1')
    view,manager=manage();local actions=choose_group(view,manager,'本机测试');local picker=group_action(view,actions,1)
    picker:onMenuSelect(entry(picker,'合成书一'))
    local search=select_row(view,picker,text('Search shelf'))
    search:setInputText('writer');button(search,text('Search')).callback()
    pump(function() return view._shelf_popup and view._shelf_popup~=search end)
    picker=view._shelf_popup
    assert(entry(picker,'合成书三') and not pcall(entry,picker,'合成书一'),'author search did not filter')
    picker:onMenuSelect(entry(picker,'合成书三'))
    search=select_row(view,picker,require('weread.lib.plugin_util').T(text('Search: %1'),'writer'))
    search:setInputText('无匹配');button(search,text('Search')).callback()
    pump(function() return view._shelf_popup and view._shelf_popup~=search end)
    picker=view._shelf_popup;assert(entry(picker,text('No matching shelf books.')))
    search=select_row(view,picker,require('weread.lib.plugin_util').T(text('Search: %1'),'无匹配'))
    search:setInputText('合成书一');button(search,text('Cancel')).callback()
    pump(function() return view._shelf_popup and view._shelf_popup~=search end)
    picker=view._shelf_popup;assert(entry(picker,text('No matching shelf books.')),'cancel changed the filter')
    picker=select_row(view,picker,text('Show all shelf books'))
    assert(entry(picker,'合成书一').mandatory=='✓' and entry(picker,'合成书三').mandatory=='✓',
        'filtering lost a selection')
    search=select_row(view,picker,text('Search shelf'));search:setInputText('未提交')
    assert(search:onCloseDialog(),'back action did not cancel search')
    pump(function() return view._shelf_popup and view._shelf_popup~=search end)
    picker=view._shelf_popup
    assert(entry(picker,'合成书一').mandatory=='✓' and entry(picker,'合成书三').mandatory=='✓',
        'back action lost unsaved selections')
    search=select_row(view,picker,text('Search shelf'));search:setInputText('未提交')
    UI:close(search);pump(function() return view._shelf_popup and view._shelf_popup~=search end)
    picker=view._shelf_popup
    assert(entry(picker,'合成书一').mandatory=='✓' and entry(picker,'合成书三').mandatory=='✓',
        'dismissing search lost unsaved selections')
    search=select_row(view,picker,text('Search shelf'));search:setInputText('合成书一')
    button(search,text('Search')).callback();pump(function() return view._shelf_popup and view._shelf_popup~=search end)
    picker=view._shelf_popup;assert(entry(picker,'合成书一') and not pcall(entry,picker,'合成书三'),'title search did not filter')
    assert(entry(picker,'合成书一').mandatory=='✓','visible selection was lost')
    -- Save while another selected book is hidden by the active filter.
    UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_LOCAL_GROUP_EVIDENCE'))..'/choose-books.png')
    picker:onMenuSelect(entry(picker,text('Save local group books')));pump(function() return host.shelf_view~=view end)
    assert_shelf_cloud();local local_group=host.shelf_groups[#host.shelf_groups]
    assert(local_group.key=='local:1' and #local_group.books==2 and local_group.books[1].bookId=='101' and local_group.books[2].bookId=='103')
    -- A long press can add and remove the same book without touching others.
    view,picker=quick_groups(shelf[2]);assert(entry(picker,'本机测试').mandatory=='')
    picker:onMenuSelect(entry(picker,'本机测试'));assert(entry(picker,'本机测试').mandatory=='✓')
    UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_LOCAL_GROUP_EVIDENCE'))..'/quick-groups.png')
    picker:onMenuSelect(entry(picker,text('Save local groups for this book')));pump(function() return host.shelf_view~=view end)
    assert(#host.shelf_groups[#host.shelf_groups].books==3)
    view,picker=quick_groups(shelf[2]);assert(entry(picker,'本机测试').mandatory=='✓')
    picker:onMenuSelect(entry(picker,'本机测试'))
    picker:onMenuSelect(entry(picker,text('Save local groups for this book')));pump(function() return host.shelf_view~=view end)
    assert(#host.shelf_groups[#host.shelf_groups].books==2)
    -- Cancelling a changed selection must leave the saved groups unchanged.
    view,picker=quick_groups(shelf[2]);picker:onMenuSelect(entry(picker,'本机测试'))
    require('weread.ui.shelf_popup').close(view)
    assert(#assert(host.library_db:getProfileState('shelf_local_groups_v1')).groups[1].books==2)
    view,picker=quick_groups(shelf[2]);picker:onMenuSelect(entry(picker,'本机测试'))
    shelf[2].bookId='104';picker:onMenuSelect(entry(picker,text('Save local groups for this book')))
    shelf[2].bookId='102';require('weread.ui.shelf_popup').close(view)
    assert(#assert(host.library_db:getProfileState('shelf_local_groups_v1')).groups[1].books==2,'changed book identity was grouped')
    view=host.shelf_view;view.on_select_groups({'archive:7','local:1'});pump(function() return host.shelf_view~=view end)
    local mixed=host.shelf_view;assert(#mixed.books==2,'mixed cloud and local groups did not deduplicate')
    local ids={};for _,book in ipairs(mixed.books) do ids[book.bookId]=true end
    assert(ids['101'] and ids['103'] and not ids['102'])
    mixed.on_select_group(nil);pump(function() return host.shelf_view~=mixed end)
    view=manage();UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_LOCAL_GROUP_EVIDENCE'))..'/local-groups.png')
    require('weread.ui.shelf_popup').close(view)
    local partial={shelf[1],shelf[2]}
    host:applyShelfSnapshot(partial,cloud);host:showShelfView('books')
    assert(host.shelf_groups[#host.shelf_groups].incomplete)
    view,manager=manage();actions=choose_group(view,manager,'本机测试');picker=group_action(view,actions,1)
    search=select_row(view,picker,text('Search shelf'));search:setInputText('合成书二')
    button(search,text('Search')).callback();pump(function() return view._shelf_popup and view._shelf_popup~=search end)
    picker=view._shelf_popup;assert(not pcall(entry,picker,'合成书一'))
    picker:onMenuSelect(entry(picker,text('Save local group books')));pump(function() return host.shelf_view~=view end)
    local preserved=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(#preserved.groups[1].books==2 and preserved.groups[1].books[1]=='101' and preserved.groups[1].books[2]=='103',
        'filtered or missing book was removed')
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
    host:showShelfView('books');view,manager=manage();actions=choose_group(view,manager,'并发新名称')
    picker=group_action(view,actions,1);search=select_row(view,picker,text('Search shelf'))
    search:setInputText('合成书一');auth('900001');host:applyShelfSnapshot(shelf,cloud)
    button(search,text('Search')).callback();UI:handleInput()
    assert(view._shelf_popup==search,'old account search reopened an obsolete picker')
    assert(not host.library_db:getProfileState('shelf_local_groups_v1'),'old account search wrote to new account')
    UI:close(search);UI:handleInput()
    assert(not view._shelf_popup,'dismissing stale search reopened a picker')
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
    local target_index;for i,row in ipairs(picker.item_table) do if row==target then target_index=i;break end end
    local target_page=math.floor((assert(target_index)-1)/picker.items_per_page)+1
    while picker.page<target_page do picker:onNextPage() end
    picker:onMenuSelect(target)
    while picker.page>1 do picker:onPrevPage() end
    picker:onMenuSelect(entry(picker,text('Save local group books')))
    pump(function() return host.shelf_view~=view end)
    local paged=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(#paged.groups[15].books==1 and paged.groups[15].books[1]=='1035')
    view,picker=quick_groups(many[35])
    picker:onMenuSelect(entry(picker,'测试组1'));picker:onMenuSelect(entry(picker,'测试组2'))
    local group_page=math.floor((17-1)/picker.items_per_page)+1
    while picker.page<group_page do picker:onNextPage() end
    picker:onMenuSelect(entry(picker,'测试组15'))
    while picker.page>1 do picker:onPrevPage() end
    picker:onMenuSelect(entry(picker,text('Save local groups for this book')))
    pump(function() return host.shelf_view~=view end)
    paged=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(paged.groups[1].books[1]=='1035' and paged.groups[2].books[1]=='1035' and #paged.groups[15].books==0)
    view,picker=quick_groups(many[35]);picker:onMenuSelect(entry(picker,'测试组1'))
    picker:onMenuSelect(entry(picker,text('Create local group for this book')))
    pump(function() return view._shelf_popup and view._shelf_popup~=picker end)
    local combined_input=assert(view._shelf_popup);combined_input:setInputText('新建兼移动');combined_input.buttons[1][2].callback()
    pump(function() return host.shelf_view~=view end)
    paged=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(#paged.groups[1].books==0 and paged.groups[2].books[1]=='1035' and paged.groups[16].books[1]=='1035')
    auth('900003');host:applyShelfSnapshot(shelf,cloud);host:showShelfView('books')
    view,picker=quick_groups(shelf[1]);local create=entry(picker,text('Create local group for this book'))
    picker:onMenuSelect(create);pump(function() return view._shelf_popup and view._shelf_popup~=picker end)
    local quick_input=assert(view._shelf_popup);quick_input:setInputText('长按新建');quick_input.buttons[1][2].callback()
    pump(function() return host.shelf_view~=view end)
    local quick_state=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(#quick_state.groups==1 and quick_state.groups[1].books[1]=='101')
    -- A stale quick picker cannot overwrite a concurrent local change.
    view,picker=quick_groups(shelf[1]);picker:onMenuSelect(entry(picker,'长按新建'))
    local fresh=assert(Model.change(quick_state,{kind='create',name='并发新组'}))
    assert(host.library_db:compareProfileState('shelf_local_groups_v1',quick_state,fresh))
    picker:onMenuSelect(entry(picker,text('Save local groups for this book')))
    local after=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
    assert(#after.groups==2 and after.groups[1].books[1]=='101','stale book picker overwrote concurrent changes')
    local top=UI:getTopmostVisibleWidget();if top~=picker then UI:close(top) end
    require('weread.ui.shelf_popup').close(view)
    host:applyShelfSnapshot(shelf,cloud);host:showShelfView('books')
    -- A picker captured for one account cannot write after switching accounts.
    view,picker=quick_groups(shelf[1]);picker:onMenuSelect(entry(picker,'长按新建'))
    auth('900004');host:applyShelfSnapshot(shelf,cloud)
    picker:onMenuSelect(entry(picker,text('Save local groups for this book')))
    assert(not host.library_db:getProfileState('shelf_local_groups_v1'),'stale book picker wrote to another account')
    require('weread.ui.shelf_popup').close(view)
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
