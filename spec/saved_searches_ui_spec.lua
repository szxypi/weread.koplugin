package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
package.preload['ui/uimanager']=function() return {
    close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    nextTick=function(_self,callback) callback() end,
} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local opened={};local open_ok=true
package.preload['weread.ui.discovery_cache']=function() return {open=function(_host,query,cursor)
    opened[#opened+1]={query=query,cursor=cursor};return open_ok
end} end
local Saved=require('weread.ui.saved_searches')
local owner={};local account='account-a';local info,menu,cancelled=nil,nil,0
local worker={start=function(self,task,callback) self.task=task;self.callback=callback;return true end,
    cancel=function() cancelled=cancelled+1 end}
local host={shelf_view=owner,discovery_epoch=0,library_db={accountKey=function() return account end},
    settings={get=function() return {source='auto'} end},client={},saved_searches_worker=worker,
    showBusy=function(self) self.busy_message={} end,closeBusy=function(self) self.busy_message=nil end,
    showInfo=function(_self,text) info=text end,
    showList=function(_self,title,rows) menu={title=title,item_table=rows};return menu end}
expect(Saved.open(host) and host.saved_searches_job,'loading did not start')
worker.callback({ok=true,items={'First','Second'}})
expect(menu and menu.title=='Saved searches' and owner._shelf_popup==menu and #menu.item_table==2,'saved menu missing')
menu.item_table[2].callback()
expect(#opened==1 and opened[1].query.keyword=='Second' and opened[1].cursor==0 and not owner._shelf_popup,
    'selection did not open cached search')

expect(Saved.open(host));local late=worker.callback;account='account-b';late({ok=true,items={'Private'}})
expect(not host.saved_searches_job and #opened==1 and not host._discovery_menu,'account change exposed saved search')
account='account-a';expect(Saved.open(host));late=worker.callback;Saved.cancel(host);late({ok=true,items={'Late'}})
expect(not host._discovery_menu and cancelled>0,'cancelled worker reopened menu')
expect(Saved.open(host));worker.callback({ok=true,items={}})
expect(info=='No saved searches yet. Search online to save results.','empty cache did not explain next step')
for _,bad in ipairs({{ok=true,items={'x','x'}},{ok=true,items={[1]='x',[3]='z'}},
    {ok=true,items={'bad\ntext'}},{ok=true,items={string.char(255)}},{ok=false}}) do
    info=nil;expect(Saved.open(host));worker.callback(bad)
    expect(info=='Could not load saved searches.' and not host._discovery_menu,'invalid worker result was shown')
end
expect(Saved.open(host));worker.callback({ok=true,items={'Gone'}});open_ok=false;menu.item_table[1].callback()
expect(info=='This saved search is no longer available. Search again to refresh it.','removed cache was not handled')
open_ok=true
expect(Saved.open(host));worker.callback({ok=true,items={'First'}})
local other_account=menu.item_table[1].callback;account='account-b';other_account()
expect(#opened==2,'menu selection crossed an account change')
account='account-a';require('weread.ui.shelf_popup').close(owner)
local input={};owner._shelf_popup=input
expect(Saved.open(host,input));late=worker.callback;owner._shelf_popup=nil;late({ok=true,items={'Late'}})
expect(not host.saved_searches_job and not host._discovery_menu,'closed input accepted a late worker')
expect(Saved.open(host));worker.callback({ok=true,items={'First'}})
local stale=menu.item_table[1].callback;owner._shelf_closed=true;stale()
expect(#opened==2,'closed owner selected cached search')
print('saved_searches_ui_spec: '..checks..' checks')
