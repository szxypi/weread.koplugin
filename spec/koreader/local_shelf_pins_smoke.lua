-- Packaged plugin, real KOReader and SQLite; entirely synthetic and offline.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local phase=assert(os.getenv('WEREAD_LOCAL_PIN_PHASE'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'});require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket');local function pump(predicate)
    local deadline=socket.gettime()+30
    while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'local pin timeout') end
end
local FileManager=require('apps/filemanager/filemanager');FileManager:showFiles(home)
local host=assert(FileManager.instance.weread);local settings=host.settings
host.isNetworkOnline=function()return false end;host.isNetworkConnected=host.isNetworkOnline
host.client.request=function()error('unexpected local pin network request')end
local function auth(id)
    settings:update_auth({account={user_vid=id,name='Synthetic'},cookies={wr_vid = id,wr_skey='synthetic-session'}},{replace_cookies=true})
end
local shelf={{bookId='101',title='合成书一',author='Alpha'},
    {bookId='102',title='合成书二',author='Beta',finishReading=1},{bookId='103',title='合成书三',author='Charlie'}}
local function show(id)
    auth(id);host:applyShelfSnapshot(shelf,{});host:showShelfView('books')
    return assert(host.shelf_view)
end
local function button(dialog,label)
    for _,row in ipairs(dialog.buttons or {}) do for _,item in ipairs(row) do if item.text==label then return item end end end
    error('button missing: '..label)
end
local text=require('weread.lib.i18n').tr
local function toggle(book,label)
    local view=assert(host.shelf_view);view.on_hold(book,'books');local dialog=assert(view._shelf_popup)
    assert(dialog:getSize().h<=Device.screen:getHeight(),'book actions exceed screen')
    assert(button(dialog,text('Change cloud membership')) and button(dialog,text('Change finished mark')),
        'full account actions missing from test menu')
    button(dialog,text(label)).callback();pump(function()return host.shelf_view~=view end)
    return host.shelf_view
end
auth('900000')
if phase=='live' then assert(host.library_db:cacheShelf(shelf,{})) end
local view=show('900000')
if phase=='live' then
    assert(view.books[1].bookId=='101' and view.books[2].bookId=='102')
    view=toggle(shelf[2],'Pin on this device')
    assert(view.books[1].bookId=='102' and view:itemStatus(view.books[1]):find(text('Local pin'),1,true))
    assert(not shelf[2].isTop,'local pin modified cloud state')
    local order=settings:get('shelf');order.sort_order='author_desc';settings:set('shelf',order);settings:flush()
    host:showShelfView('books');view=host.shelf_view
    assert(view.books[1].bookId=='102' and view.books[2].bookId=='103' and view.books[3].bookId=='101',
        'local pin did not preserve the chosen order')
    host:showShelfView('books','合成书一');view=host.shelf_view
    assert(#view.books==1 and view.books[1].bookId=='101','local pin bypassed shelf search')
    order.sort_order='default';settings:set('shelf',order);settings:flush();host:showShelfView('books');view=host.shelf_view
    -- A second writer changes the account's pins after this page loaded.
    local model=require('weread.lib.local_shelf_pins');local original=host.shelf_pins_original
    local concurrent=assert(model.toggle(original,shelf[3]))
    assert(host.library_db:compareProfileState(model.KEY,original,concurrent))
    local show_info=host.showInfo;local notice
    host.showInfo=function(_self,message)notice=message end
    view.on_hold(shelf[2],'books');local dialog=assert(view._shelf_popup)
    button(dialog,text('Remove local pin')).callback();pump(function()return notice~=nil end)
    host.showInfo=show_info
    local actual=host.library_db:getProfileState(model.KEY)
    assert(model.contains(actual,shelf[2]) and model.contains(actual,shelf[3]),'stale action overwrote another writer')
    view.on_page_changed(1);view=host.shelf_view
    assert(model.contains(host.shelf_pins_state,shelf[2]) and model.contains(host.shelf_pins_state,shelf[3]),
        'reopening did not load concurrent changes')
    assert(view.books[1].bookId=='102' and view.books[2].bookId=='103',
        'reopening reused stale sorted pages after concurrent changes')
    assert(host.library_db:compareProfileState(model.KEY,actual,original))
    view.on_page_changed(1);view=host.shelf_view
    assert(view.books[1].bookId=='102' and view.books[2].bookId=='101' and not model.contains(host.shelf_pins_state,shelf[3]),
        'reopening lost saved pin or reused stale sorted pages')
    local other=show('900001');assert(other.books[1].bookId=='101','pin crossed account')
    view=show('900000');assert(view.books[1].bookId=='102','pin did not return with account')
    local options=settings:get('shelf');options.view_mode='cover';settings:set('shelf',options);settings:flush()
    host:showShelfView('books');view=host.shelf_view
    assert(view.cover_mode and view._item_rows[1]._pinned_badge,'cover omitted local badge')
    local cell=view._item_rows[1];local pin,finished=cell._pinned_badge,cell._finished_badge
    assert(finished and pin.overlap_offset[1]+pin:getSize().w<=finished.overlap_offset[1],
        'local pin badge overlaps finished badge')
    UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_LOCAL_PIN_EVIDENCE'))..'/cover.png')
elseif phase=='reopen' then
    assert(view.books[1].bookId=='102','offline restart lost pin')
    view=toggle(shelf[2],'Remove local pin')
    assert(view.books[1].bookId=='101' and not view:itemStatus(shelf[2]):find(text('Local pin'),1,true),'unpin failed')
    assert(not shelf[2].isTop,'unpin modified cloud state')
elseif phase=='unpin_reopen' then
    assert(view.books[1].bookId=='101' and not view:itemStatus(shelf[2]):find(text('Local pin'),1,true),
        'offline restart lost the unpin')
else error('unknown phase') end
print('\nWEREAD_LOCAL_PINS='..require('json').encode({result='PASS',phase=phase,network_requests=0}))
os.exit(0)
