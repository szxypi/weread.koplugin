-- Test the actual portal and cache in separate, network-blocked processes.
require('ffi').log=function() end;require('setupkoenv')
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope,stage=assert(arg[2]),assert(arg[3])
local personal=scope=='account'
local shared=scope=='shared'
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local PluginLoader=require('pluginloader')
PluginLoader.enabled_plugins,PluginLoader.disabled_plugins,PluginLoader.loaded_plugins={},{},{}
for _,entry in ipairs(PluginLoader:_discover()) do if entry.name=='weread' then PluginLoader:_load{entry} end end
assert(#PluginLoader.enabled_plugins==1)
local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
local host=assert(FM.instance.weread)
host.isNetworkConnected=function() return false end
host.isNetworkLinkAvailable=host.isNetworkConnected
host.client.request=function() error('bookstore made an offline request') end
local redraw_covers
host.fetchVisibleShelfCovers=function(_,_,_,options) redraw_covers=options.on_redraw end
local UI=require('ui/uimanager')
local function flush_actions()
    UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput()
end
local Cache=require('weread.ui.discovery_cache')
local account
local function switch_account(vid)
    host.settings:set('account',vid and {name='Synthetic',user_vid=vid,login_method='qr'} or {})
    host.settings:set('cookies',{})
    assert(host.settings:flush())
    account=host.library_db:accountKey()
    assert((account~=nil)==(vid~=nil))
end
if personal or shared and stage~='write' and stage~='replace' then switch_account('900000') end

local function batch(query,cursor)
    local state={account=account,source_kind=account and 'native' or 'public',source_revision='synthetic',
        cursor=cursor,next_cursor=cursor+20,has_more=cursor==0,loaded_at=os.time(),books={}}
    for key,value in pairs(query) do state[key]=value end
    for index=1,20 do
        state.books[index]={bookId=tostring(900000+cursor+index),title='Fixture book '..index,author='',cover='',category=''}
    end
    return state
end
local query=personal and {kind='search',keyword='Synthetic search'}
    or {kind='category',category_id='rising',category_title='Synthetic rank',rank=true}
local account_fallback={kind='search',keyword='Newer search'}
local function focus(index)
    local view=host.shelf_view
    local focused=assert(view._item_rows[index])
    for row,items in ipairs(view.layout) do for column,item in ipairs(items) do
        if item==focused then view:moveFocusTo(column,row,require('ui/widget/focusmanager').FORCED_FOCUS) end
    end end
end
local function assert_position(index)
    local view=assert(host.shelf_view)
    assert(host.discovery_state.cursor==0 and host.discovery_state.cached and view.page==2)
    assert(view:getFocusedBookId()==tostring(900000+view.page_size+index),'focused book did not survive reopening')
end
local function press(label)
    local translated=require('weread.lib.i18n').tr(label)
    for _,button in ipairs(host.shelf_view._action_buttons) do
        if button.text==translated then button.callback();flush_actions();return end
    end
    error('offline batch unavailable: '..label)
end
if stage=='write' then
    local first=batch(query,0);assert(Cache.save(host,first))
    assert(Cache.save(host,batch(query,20),first,true))
    local other=personal and account_fallback or {kind='category',category_id='different',category_title='Newer rank',rank=true}
    assert(Cache.save(host,batch(other,0)))
    if shared then
        assert(Cache.remember(host,assert(Cache.read(host,query,20)),{anchor=1,focus='900021'}))
        switch_account('900000')
        assert(Cache.save(host,batch(account_fallback,0)))
        assert(Cache.open(host,query,0) and host.discovery_state._shared_public_category)
        press('Next batch')
    else
        assert(Cache.open(host,query,20))
    end
    assert(host.discovery_state.cursor==20)
    press('Previous batch')
    assert(host.discovery_state.cursor==0)
    local writes,remember=0,Cache.remember
    Cache.remember=function(...) writes=writes+1;return remember(...) end
    local first_view=host.shelf_view
    local function page_dialog(view)
        local button=assert(view._page_buttons[2])
        assert(button.enabled,'page number could not be selected')
        UI:forceRePaint();button:onTapSelectButton();flush_actions()
        return assert(view._shelf_popup)
    end
    local jump=page_dialog(first_view)
    redraw_covers(first_view.page);flush_actions()
    assert(host.shelf_view==first_view and first_view._shelf_popup==jump,'cover redraw closed the page selector')
    local stale_submit=jump.buttons[2][2].callback
    for _,invalid in ipairs({'0','2.5','2e1',tostring(first_view.page_count+1)}) do
        jump:setInputText(invalid);stale_submit();flush_actions()
        assert(host.shelf_view==first_view and first_view._shelf_popup==jump,'invalid page moved the list or lost input')
    end
    jump:setInputText('2');stale_submit();flush_actions()
    assert(host.shelf_view~=first_view and host.shelf_view.page==2 and not first_view._shelf_popup
        and host.discovery_state.cursor==0,'page jump moved to the wrong batch or page')
    local second_view=host.shelf_view
    stale_submit();flush_actions()
    assert(host.shelf_view==second_view,'an old jump dialog changed the replacement page')
    focus(2)
    redraw_covers(2);flush_actions()
    assert_position(2)
    assert(writes==0,'changing pages or repainting wrote the position')
    local view=host.shelf_view
    view._navigation_buttons[1].callback();flush_actions()
    assert(host.shelf_view._discovery_tab=='home' and writes==1,'leaving the bookstore did not save once')
    host.shelf_view._navigation_buttons[3].callback();flush_actions()
    assert_position(2)
    UI:flushSettings()
    assert(writes==1,'an unchanged position was written again')
    focus(3);UI:flushSettings()
    assert(writes==2,'flushing settings did not save the new focus')
elseif stage=='reopen' then
    host:openBookstore()
    assert_position(3)
    assert(host.discovery_state.kind==query.kind and host.discovery_state.keyword==query.keyword
        and host.discovery_state.category_id==query.category_id and not host.discovery_state.source_revision)
    if shared then
        assert(host.discovery_state._shared_public_category and host.discovery_state.account==account)
        press('Next batch');assert(host.discovery_state._shared_public_category and host.discovery_state.cursor==20)
        host:closeWeReadUI();host.discovery_state=nil
        switch_account('900001')
        host:openBookstore();assert(not host.discovery_state,'shared position crossed accounts')
        host:closeWeReadUI()
        switch_account(nil)
        host:openBookstore()
        assert(host.discovery_state.cursor==20 and host.shelf_view:getFocusedBookId()=='900021'
            and not host.discovery_state._shared_public_category,'account browsing changed the guest position')
    end
elseif stage=='replace' then
    assert(shared)
    switch_account(nil)
    local changed=batch(query,0);changed.books[1].title='Another guest result'
    assert(Cache.save(host,changed))
else
    assert(shared and stage=='reopen-stale')
    host:openBookstore()
    assert(host.discovery_state and host.discovery_state.kind=='search'
        and host.discovery_state.keyword==account_fallback.keyword and not host.discovery_state._shared_public_category,
        'obsolete public position opened a different generation')
end
print('WEREAD_BOOKSTORE_POSITION='..scope..'/'..stage)
