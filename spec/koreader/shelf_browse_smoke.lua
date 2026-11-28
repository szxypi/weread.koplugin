-- Packaged file-manager plugin and real SQLite, reopened in independent processes.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local phase=assert(os.getenv('WEREAD_LOCAL_GROUP_PHASE'))
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
G_reader_settings:saveSetting('items_per_page',6)
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1);package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket')
local function wait(predicate)
    local deadline=socket.gettime()+30
    while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,phase) end
end
local FileManager=require('apps/filemanager/filemanager');FileManager:showFiles(home)
local host=assert(FileManager.instance.weread);local settings=host.settings;local db=host.library_db
host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
local requests=0
host.client.request=function() requests=requests+1;error('unexpected bookshelf network request') end
local key=require('weread.lib.shelf_browse').KEY
local filters_key=require('weread.lib.shelf_filters').KEY
local tr=require('weread.lib.i18n').tr
local function auth(id)
    settings:update_auth({account={user_vid=id,name='Synthetic'},cookies={wr_vid = id,wr_skey='synthetic-session'}},
        {replace_cookies=true})
    host:onWeReadAccountChanged()
end
local function set_layout(paged)
    local shelf=settings:get('shelf');shelf.view_mode='list';shelf.paginated=paged;shelf.sort_order='default'
    settings:set('shelf',shelf);settings:flush()
end
local search_text='离线书'
local public_text='合成公众号'
local book_rows,group_ids={},{}
for index=1,44 do
    local uid=tostring(910000+index)
    book_rows[index]={bookId=uid,title=search_text..' '..index,finishReading=index%2}
    group_ids[index]=uid
end
book_rows[#book_rows+1]={bookId='960000',title='Other',finishReading=0}
book_rows[#book_rows+1]={bookId='MP_WXS_Synthetic',title=public_text}
local function cache(insert)
    local entries,ids={},{}
    if insert then entries[1]={bookId='990000',title=search_text..' 新书',finishReading=1};ids[1]='990000' end
    for _,book in ipairs(book_rows) do entries[#entries+1]=book end
    for _,id in ipairs(group_ids) do ids[#ids+1]=id end
    assert(db:cacheShelf(entries,{{archiveId=7,name='Synthetic group',bookIds=ids}}))
end
local function changed(view)
    wait(function() return host.shelf_view and host.shelf_view~=view end)
    return host.shelf_view
end
local function search(view,query)
    view.on_search();local input=assert(view._shelf_popup)
    input:setInputText(query);input.buttons[1][2].callback()
    return changed(view)
end
local writes,write=0,db.putProfileState
db.putProfileState=function(self,name,value)
    if name==key then writes=writes+1 end
    return write(self,name,value)
end
local function focus(view,item)
    for y,row in ipairs(view.layout) do
        if row[1]==item then view:moveFocusTo(1,y,require('ui/widget/focusmanager').FORCED_FOCUS);return end
    end
    error('book row is missing from focus layout')
end

local function filter(view,label)
    view.on_filter();local dialog=assert(view._shelf_popup)
    for _,row in ipairs(dialog.buttons) do for _,button in ipairs(row) do
        if button.text==tr(label) then button.callback();return changed(view) end
    end end
    error('filter unavailable: '..label)
end

if phase=='seed_paged' then
    auth('900000');set_layout(true);cache(false);host:showBookshelf()
    local view=assert(host.shelf_view)
    view=filter(view,'Only show finished books');assert(host.shelf_filters.reading=='finished')
    view=filter(view,'Only show downloaded books');assert(host.shelf_filters.download=='downloaded')
    view=filter(view,'Only show finished books')
    assert(not host.shelf_filters.reading and host.shelf_filters.download=='downloaded')
    view=filter(view,'Only show downloaded books');assert(not host.shelf_filters.download)
    view=filter(view,'Only show finished books')
    view=filter(view,'Only show not-downloaded books')
    local filters=assert(db:getProfileState(filters_key))
    assert(filters.reading=='finished' and filters.download=='not_downloaded')
    view.on_select_group('archive:7');view=changed(view)
    view=search(view,search_text)
    view:turnShelfPage(1);view=changed(view)
    local chosen=assert(view._item_rows[#view._item_rows]);focus(view,chosen)
    assert(view.page==2 and view:getFocusedBookId()==chosen.book.bookId and writes==0)
    assert(view:onClose() and not host.shelf_view and writes==1)
    local saved=assert(db:getProfileState(key))
    assert(saved.keyword==search_text and saved.group_key=='archive:7' and saved.page==2 and saved.focus_book_id==chosen.book.bookId
        and saved.filters.reading=='finished' and saved.filters.download=='not_downloaded')
    cache(true)
elseif phase=='reopen_paged' then
    local saved=assert(db:getProfileState(key));host:showBookshelf()
    local view=assert(host.shelf_view)
    assert(view.keyword==search_text and view.group_key=='archive:7' and view.page==3
        and view:getFocusedBookId()==saved.focus_book_id,'paged shelf did not follow the reordered focused book after restart')
    assert(host.shelf_filters.reading=='finished' and host.shelf_filters.download=='not_downloaded' and #view.books==23,
        'offline reopen did not restore both filters')
    local stale=view._shelf_checkpoint
    auth('900001');stale();assert(not db:getProfileState(key) and writes==0,'old bookshelf wrote a new account preference')
    set_layout(false);cache(false);host:showBookshelf()
    view=assert(host.shelf_view);assert(not view.paged and not view.keyword and not view.group_key)
    assert(next(host.shelf_filters)==nil and not db:getProfileState(filters_key),'the second account inherited filters')
    local shelf=settings:get('shelf');shelf.filter_download='downloaded';settings:set('shelf',shelf);settings:flush()
    host:closeWeReadUI();host:showBookshelf();view=assert(host.shelf_view)
    assert(host.shelf_filters.download=='downloaded','the legacy device default was not applied')
    view=filter(view,'All')
    assert(next(assert(db:getProfileState(filters_key)))==nil and settings:get('shelf').filter_download=='downloaded',
        'clearing account filters discarded the legacy device default')
    writes=0
    view=search(view,search_text);UI:forceRePaint();view.scroll:_scrollBy(0,620);UI:forceRePaint()
    local scrolled=view:getBrowsePosition()
    assert(scrolled.scroll_offset.y>0 and scrolled.book_id~=book_rows[1].bookId,'fixture did not scroll the continuous shelf')
    host:onSuspend()
    local scroll=assert(db:getProfileState(key));assert(writes==1 and scroll.book_id==scrolled.book_id and scroll.inset==scrolled.inset)
    cache(true)
elseif phase=='reopen_continuous' then
    auth('900001');local saved=assert(db:getProfileState(key));host:showBookshelf()
    local view=assert(host.shelf_view);UI:forceRePaint();local position=view:getBrowsePosition()
    assert(next(host.shelf_filters)==nil and settings:get('shelf').filter_download=='downloaded',
        'explicitly empty account filters fell back to the device default after restart')
    assert(not view.paged and view.keyword==search_text and position.book_id==saved.book_id and position.inset==saved.inset
        and position.scroll_offset.y>saved.scroll_offset.y,
        'continuous shelf did not restore its visible book after restart: '..require('json').encode{
            position=position,saved=saved,keyword=view.keyword,paged=view.paged})
    view.on_switch('public_account');view=changed(view);view=search(view,public_text)
    assert(view.mode=='public_account' and #view:getVisibleBooks()==1)
    for _,button in ipairs(view._navigation_buttons) do if button.text==tr('Home') then button.callback();break end end
    assert(changed(view)._discovery_tab=='home' and writes==1,'leaving the shelf did not save its active tab')
    local public=assert(db:getProfileState(key));assert(public.mode=='public_account' and public.keyword==public_text)
else
    assert(phase=='reopen_public');auth('900001');host:showBookshelf()
    local view=assert(host.shelf_view);assert(view.mode=='public_account' and view.keyword==public_text and #view:getVisibleBooks()==1)
    host:onFlushSettings();assert(writes==0,'unchanged shelf position was written again')
    host:closeWeReadUI()
    auth('900000');set_layout(true);host:showBookshelf()
    assert(host.shelf_view.mode=='books' and host.shelf_view.keyword==search_text and host.shelf_view.page==3
        and host.shelf_view.group_key=='archive:7','returning to the first account lost its previous shelf position')
    assert(host.shelf_filters.reading=='finished' and host.shelf_filters.download=='not_downloaded')
    host:closeWeReadUI();assert(db:putProfileState(filters_key,{reading='unfinished'}));host:showBookshelf()
    local modified=assert(host.shelf_view)
    assert(modified.group_key=='archive:7' and modified.keyword==search_text and modified.page==1,
        'changed filters reused the old result page')
    modified:turnShelfPage(1);modified=changed(modified);assert(modified.page==2)
    host:closeWeReadUI();assert(db:cacheShelf(book_rows,{}));host:showBookshelf()
    local all=assert(host.shelf_view)
    assert(not all.group_key and all.keyword==search_text and all.page==1,
        'removed group restored its old focus in the full shelf')
end
assert(requests==0)
print('\nWEREAD_SHELF_BROWSE='..require('json').encode({result='PASS',phase=phase,network_requests=requests}))
os.exit(0)
