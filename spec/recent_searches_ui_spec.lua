package.path='./?.lua;./?/init.lua;'..package.path
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local top
package.preload['ui/uimanager']=function() return {
    close=function(_,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    show=function(_,widget) top=widget end,
    nextTick=function(_,callback) callback() end,
} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,v) return v end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
local History=require('weread.lib.recent_searches')
local Recent=require('weread.ui.recent_searches')
local account=nil;local owner={};local menu,info,opened
local host={shelf_view=owner,settings={get=function() return {source='auto'} end},library_db={accountKey=function() return account end},
    showList=function(_,title,items)
        menu={title=title,item_table=items}
        function menu:onMenuSelect(item) item.callback();if self.close_callback then self.close_callback() end end
        return menu
    end,
    showInfo=function(_,text) info=text end,
    loadDiscoveryBatch=function(_,kind,keyword,cursor,_previous,_refresh,context) opened={kind,keyword,cursor,context} end}
expect(not Recent.open(host) and info=='No recent searches yet.','empty message absent')
expect(History.record(host,'auto',false) and History.record(host,'public',true),'test history missing')
expect(Recent.open(host) and menu.title=='Recent searches' and #menu.item_table==3,'history menu missing')
expect(menu.item_table[1].mandatory=='Public search' and menu.item_table[2].mandatory=='WeRead search','search modes missing')
menu.item_table[1].callback()
expect(opened and opened[1]=='search' and opened[2]=='public' and opened[4].public_search,'public search mode lost')
expect(Recent.open(host));menu.item_table[2].callback()
expect(opened[2]=='auto' and opened[4]==nil,'automatic search mode lost')
expect(Recent.open(host));menu:onMenuHold(menu.item_table[1]);expect(top and top.ok_callback,'remove confirmation absent')
top.cancel_callback();expect(#History.list(host).entries==2,'cancel removed history')
menu:onMenuHold(menu.item_table[1]);top.ok_callback()
expect(#History.list(host).entries==1 and menu.item_table[1].text=='auto','confirmed removal failed')
menu:onMenuSelect(menu.item_table[2]);expect(top and top.ok_callback,'clear confirmation absent')
top.ok_callback();expect(#History.list(host).entries==0 and info=='No recent searches yet.','clear failed')
expect(History.record(host,'one',false) and Recent.open(host));menu:onMenuHold(menu.item_table[1]);local old=top
expect(History.record(host,'new',false),'concurrent search failed');old.ok_callback()
expect(#History.list(host).entries==2 and info=='Recent searches changed or could not be saved. Please try again.',
    'stale confirmation removed concurrent search')
local callback=menu.item_table[1].callback;account='other';callback()
expect(opened[2]=='auto','stale menu crossed account boundary')
account=nil;require('weread.ui.shelf_popup').close(owner)
local input={};owner._shelf_popup=input;expect(Recent.open(host,input),'input-owned menu failed')
local previous=menu;require('weread.ui.shelf_popup').close(owner);previous.item_table[1].callback()
expect(opened[2]=='auto','closed menu still opened a search')
local Discovery=require('weread.ui.discovery')
local request=package.loaded['weread.ui.discovery_request']
package.loaded['weread.ui.discovery_request']={load=function(_,kind,term) return kind..':'..term end}
local record=History.record;History.record=function() error('synthetic history storage failure') end
expect(Discovery.loadDiscoveryBatch(host,'search','still works',0)=='search:still works',
    'search failed when local history could not be saved')
History.record=record;package.loaded['weread.ui.discovery_request']=request
print('recent_searches_ui_spec: '..checks..' checks')
