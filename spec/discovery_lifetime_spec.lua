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
        local view={page=data.page,page_size=data.page_size,home_layout=data.home_layout,data=data,callbacks=callbacks}
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
    local options={title='Home',home={},on_refresh=action,actions={{text='Action',callback=action}}}
    local books={};for book_index=1,13 do books[#books+1]={bookId=tostring(book_index)} end
    function state.open(tab) plugin:showDiscoveryPage(tab or 'home',books,options);return plugin.shelf_view end
    plugin.homeStatusText=function() return '' end;plugin.homeReadingSummary=plugin.homeStatusText
    return plugin,state
end
local plugin,state=host();local view=state.open()
plugin:closeWeReadUI()
view.data.navigation[3].callback()
expect(state.calls==0 and not plugin.shelf_view,'closed home navigation reopened a page')

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
        view.data.actions[1].callback();view.data.navigation[3].callback();cover(1)
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
plugin,state=host();view=state.open();view.callbacks.on_search()
local first=assert(view._shelf_popup);local old=first.buttons[1][2].callback
view.callbacks.on_search();dialog=assert(view._shelf_popup);old()
expect(view._shelf_popup==dialog and state.calls==0,'replaced search operated on new dialog')
dialog.input=' words ';dialog.buttons[1][2].callback();drain()
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
print('discovery_lifetime_spec: '..checks..' checks')
