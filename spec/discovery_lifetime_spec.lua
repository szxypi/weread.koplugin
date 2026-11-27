package.path='./?.lua;./?/init.lua;'..package.path
local checks,queue,shown=0,{},{}
local function expect(value,message) checks=checks+1;assert(value,message) end
local UI={}
function UI:nextTick(callback) queue[#queue+1]=callback end
function UI:show(widget) shown[#shown+1]=widget end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
local function drain() while #queue>0 do local work=queue;queue={};for _task_index,callback in ipairs(work) do callback() end end end
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,T=function(value) return value end} end
package.preload['ui/widget/inputdialog']=function() return {new=function(_self,data)
    data.getInputText=function(self) return self.input end
    return data
end} end
package.preload['weread.ui.library_view']=function() return {
    getLayout=function() return {page_size=6,columns=3,rows=2} end,
    show=function(data,callbacks)
        local view={page=data.page,page_size=data.page_size,home_layout=data.home_layout,books=data.books,data=data,callbacks=callbacks}
        view.onCloseWidget=function(self) self._shelf_closed=true;require('weread.ui.shelf_popup').close(self) end
        return view
    end,
} end
local Discovery=require('weread.ui.discovery')
local function host()
    local state={account='account-a',auth={vid='XXX',epoch=1},disk=true,calls=0}
    local plugin=setmetatable({settings={get=function(_self,key) return key=='shelf' and {source=state.source} or {} end,
        get_auth_scope=function() return state.auth end,auth_scope_matches=function() return state.disk end},
        library_db={accountKey=function() return state.account end},ui={document={}},
        discovery_state={},shelf_regular={},shelf_groups={},
        getShelfCoverCache=function() return {pathFor=function() end} end,
        cancelShelfCovers=function() end,isBookDownloaded=function() return false end,
        fetchVisibleShelfCovers=function(_self,_view,_books,options) state.covers=options end,
        showInputDialog=function(_self,dialog) UI:show(dialog) end,
        closeHomeControls=function() end,
    },{__index=Discovery})
    local function action() state.calls=state.calls+1 end
    for _name_index,name in ipairs({'showBookRecord','showHomeQuickSettings','showProfile','showBookshelf','showHome','loadDiscoveryBatch'}) do plugin[name]=action end
    plugin.closeWeReadUI=function(self)
        if self.shelf_view then UI:close(self.shelf_view) end
        self.shelf_view=nil;self.discovery_epoch=(self.discovery_epoch or 0)+1
    end
    local options={title='Home',home={},on_refresh=action,actions={{text='Action',callback=action,hold_callback=action}}}
    local books={};for book_index=1,13 do books[#books+1]={bookId=tostring(book_index)} end
    function state.open(tab) plugin:showDiscoveryPage(tab or 'home',books,options);return plugin.shelf_view end
    plugin.homeStatusText=function() return '' end;plugin.homeReadingSummary=plugin.homeStatusText
    return plugin,state
end
local plugin,state=host();local view=state.open()
plugin:closeWeReadUI()
view.data.navigation[3].callback()
expect(state.calls==0 and not plugin.shelf_view,'closed home navigation reopened a page')

plugin,state=host();view=state.open();view.page=2
view.getFocusedBookId=function() return '8' end
view:onFlushSettings()
expect(plugin._home_browse_position.anchor==7 and plugin._home_browse_position.focus=='8',
    'leaving home did not remember the page and book')
local restored
plugin.library_db.getShelf=function() return {} end
plugin.library_db.getShelfArchives=function() return {} end
plugin.applyShelfSnapshot=function() end
plugin.homePreferences=function() return {recent_limit=24} end
plugin.homeShortcuts=function() return {} end
plugin.showDiscoveryPage=function(_,_,_,options) restored=options end
plugin.shelf_view=nil
Discovery.showHome(plugin)
expect(restored.rotation_anchor==7 and restored.focus_book_id=='8','home did not restore its own account position')
state.account='account-b';view:onFlushSettings()
expect(plugin._home_browse_position.account=='account-a','stale home saved a position for a different account')
Discovery.showHome(plugin)
expect(not restored.rotation_anchor and not restored.focus_book_id,'home opened using another account position')

local events={closed=function(p) p:closeWeReadUI() end,replaced=function(_p,s) s.open() end,
    account=function(_p,s) s.account='account-b' end,epoch=function(p) p.discovery_epoch=1 end,
    session=function(p) p._reader_session_gen=1 end,document=function(p) p.ui.document={} end,
    snapshot=function(p) p.shelf_regular={} end,query=function(p) p.discovery_state={} end,
    source=function(_p,s) s.source='web' end,
    auth=function(_p,s) s.auth={vid='XXX',epoch=2} end,disk=function(_p,s) s.disk=false end}
for _tab_index,tab in ipairs({'home','store'}) do
    for name,change in pairs(events) do
        plugin,state=host();view=state.open(tab);local cover=state.covers.on_redraw
        view.callbacks.on_search();local input=assert(view._shelf_popup)
        change(plugin,state);local active=plugin.shelf_view
        view.callbacks.on_search();view.callbacks.on_refresh();view.callbacks.on_settings();view.callbacks.on_summary()
        view.callbacks.on_select({bookId='1'});view.callbacks.on_page_changed(2)
        view.data.actions[1].callback();view.data.actions[1].hold_callback();view.data.navigation[3].callback();cover(1)
        input.getInputText=function() error('stale scoped input accessed') end
        input.buttons[1][2].callback()
        expect(state.calls==0 and plugin.shelf_view==active,'stale discovery action: '..tab..'/'..name)
    end
end
plugin,state=host();view=state.open();view.callbacks.on_search()
local dialog=assert(view._shelf_popup);dialog.input=' words '
local submit=dialog.buttons[1][2].callback
plugin:closeWeReadUI();dialog.getInputText=function() error('closed input accessed') end
submit();expect(state.calls==0,'closed search dispatched a query')
plugin,state=host();view=state.open('store')
plugin.discovery_state={kind='search',keyword='existing query',account='account-a'}
plugin:showDiscoverySearch();dialog=assert(view._shelf_popup)
expect(dialog.input=='existing query','store search did not preserve the current query')
require('weread.ui.shelf_popup').close(view)
plugin.discovery_state.account='other';plugin:showDiscoverySearch();dialog=assert(view._shelf_popup)
expect(dialog.input=='','foreign account query was displayed')
require('weread.ui.shelf_popup').close(view)
plugin:showDiscoverySearch('explicit query');dialog=assert(view._shelf_popup)
expect(dialog.input=='explicit query','editing a suggestion lost its original query')
plugin.loadDiscoveryBatch=function(_self,kind,keyword,cursor)
    expect(kind=='search' and keyword=='edited query' and cursor==0,'edited query was not submitted')
    state.calls=state.calls+1
end
dialog.input='edited query';dialog.buttons[1][2].callback()
expect(state.calls==1 and not view._shelf_popup,'edited search did not close and submit')
plugin:showDiscoverySearch();dialog=assert(view._shelf_popup)
plugin.loadDiscoveryBatch=function(_self,kind,keyword,cursor,_previous,_refresh,context)
    expect(kind=='search' and keyword=='public query' and cursor==0 and context.public_search,
        'public search did not select its source')
    state.calls=state.calls+1
end
dialog.input=' public query ';dialog.buttons[2][2].callback()
expect(state.calls==2 and not view._shelf_popup,'public search did not submit exactly once')
plugin:showDiscoverySearch('bad\nquery');dialog=assert(view._shelf_popup)
expect(dialog.input=='','invalid prefilled query was displayed')
plugin,state=host();view=state.open('home')
plugin.discovery_state={kind='search',keyword='store query',account='account-a'}
plugin:showDiscoverySearch();dialog=assert(view._shelf_popup)
expect(dialog.input=='','home search inherited a store query')
plugin,state=host();view=state.open('store')
plugin.discovery_state={kind='search',keyword='private query',account='account-a'};state.disk=false
plugin:showDiscoverySearch()
expect(not view._shelf_popup,'stale login exposed a stored search term')
plugin,state=host();view=state.open();view.callbacks.on_search()
local first=assert(view._shelf_popup);local old=first.buttons[1][2].callback
view.callbacks.on_search();dialog=assert(view._shelf_popup);old()
expect(view._shelf_popup==dialog and state.calls==0,'replaced search operated on new dialog')
dialog.input='　\194\160';dialog.buttons[1][2].callback()
expect(state.calls==0 and view._shelf_popup==dialog,'blank Unicode search dispatched or closed')
plugin.loadDiscoveryBatch=function(_self,kind,keyword,cursor)
    expect(kind=='search' and keyword=='words' and cursor==0,'Unicode search edges were not trimmed')
    state.calls=state.calls+1
end
dialog.input='　words\194\160';dialog.buttons[1][2].callback();drain()
expect(state.calls==1 and plugin.shelf_view==view and not view._shelf_popup,'current search did not submit exactly once')
old();expect(state.calls==1,'old search submitted twice')
plugin,state=host();view=state.open();view.callbacks.on_search();dialog=assert(view._shelf_popup)
state.covers.on_redraw(2)
expect(plugin.shelf_view==view and view._shelf_popup==dialog,'cover redraw dismissed search')
dialog.buttons[1][1].callback();drain()
expect(plugin.shelf_view~=view and plugin.shelf_view.page==2,'search cancel lost pending redraw')
plugin,state=host();view=state.open();view.callbacks.on_search();dialog=assert(view._shelf_popup)
state.covers.on_redraw(2);plugin.loadDiscoveryBatch=function(self) state.calls=state.calls+1;self:closeWeReadUI() end
dialog.input='next';dialog.buttons[1][2].callback();drain()
expect(not plugin.shelf_view and state.calls==1,'old cover redraw overrode new search')
plugin,state=host();view=state.open()
plugin.showList=function(_self,_title,items) return {item_table=items} end
local categories={loaded_at=os.time(),ranks={{id='rising',title='Rank',rank=true,children={}}},categories={}}
plugin:showDiscoveryCategoryPicker(categories)
local picker=assert(plugin._discovery_menu);local choose=picker.item_table[1].sub_item_table[1].callback
state.covers.on_redraw(2)
expect(view._shelf_popup==picker and plugin.shelf_view==view,'cover redraw dismissed category menu')
state.open();local replacement=plugin.shelf_view;choose()
expect(not plugin._discovery_menu and not view._shelf_popup and state.calls==0 and plugin.shelf_view==replacement,
    'old category menu operated after page replacement')
plugin:showDiscoveryCategoryPicker(categories);picker=assert(plugin._discovery_menu)
picker.item_table[1].sub_item_table[1].callback();drain()
expect(state.calls==1 and not plugin._discovery_menu,'current category selection ignored')

-- The first store entry is deferred so that the visible page owns the public
-- request. A new action, account, or page must be able to supersede it.
local saved_cache=package.loaded['weread.ui.discovery_cache']
local cached
package.loaded['weread.ui.discovery_cache']={read=function() return cached end}
local function empty_store()
    local p,s=host();p.discovery_state=nil
    p.isNetworkConnected=function() return true end
    p.loadDiscoveryBatch=function(_self,kind,keyword,cursor,previous,refresh,context)
        s.calls=s.calls+1;s.request={kind=kind,keyword=keyword,cursor=cursor,
            previous=previous,refresh=refresh,context=context}
    end
    return p,s
end
plugin,state=empty_store();plugin:openBookstore();view=plugin.shelf_view;drain()
expect(state.calls==1 and state.request.kind=='category' and state.request.cursor==0
    and state.request.context.category_id=='rising' and state.request.context.rank
    and state.request.context.category_title=='Rising · Published','first store entry did not load the public chart')
view.callbacks.on_refresh()
expect(state.calls==2 and state.request.refresh and state.request.context.category_id=='rising',
    'empty store refresh did not retry the public chart')
local changes={
    closed=function(p) p:closeWeReadUI() end,
    replaced=function(p) p:showDiscoveryPage('home',{}, {}) end,
    account=function(_p,s) s.account='other' end,
    auth=function(_p,s) s.auth={vid='XXX',epoch=2} end,
    selected=function(p) p.discovery_state={} end,
    request=function(p) p.discovery_loading=true end,
    catalog=function(p) p.category_catalog_request={} end,
    popup=function(p) p.shelf_view._shelf_popup={} end,
    offline=function(p) p.isNetworkConnected=function() return false end end,
}
for name,change in pairs(changes) do
    plugin,state=empty_store();plugin:openBookstore();change(plugin,state);drain()
    expect(state.calls==0,'initial public chart overrode '..name)
end
plugin,state=empty_store();plugin:openBookstore();plugin:openBookstore();drain()
expect(state.calls==1,'reopening empty store dispatched more than one initial request')
cached={account='account-a',kind='category',category_title='saved',books={},history={},loaded_at=os.time()}
plugin,state=empty_store();plugin:openBookstore();drain()
expect(state.calls==0 and plugin.discovery_state==cached,'initial chart replaced cached store')
package.loaded['weread.ui.discovery_cache']=saved_cache
plugin,state=host();view=state.open()
plugin.library_db.getShelfStatus=function() return {present=true,book={finishReading=1}} end
local owner_popup={};require('weread.ui.shelf_popup').show(view,owner_popup,function() end)
require('weread.ui.finish_offline').refresh_view(plugin,'1')
view.callbacks.on_page_changed(2)
require('weread.ui.shelf_popup').close(view);drain()
expect(plugin.shelf_view~=view and plugin.shelf_view.page==2 and plugin.shelf_view.books[1].finishReading==1,
    'another deferred page redraw discarded the finished-mark refresh')
print('discovery_lifetime_spec: '..checks..' checks')
