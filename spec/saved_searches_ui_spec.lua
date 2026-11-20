package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local confirmation
package.preload['ui/uimanager']=function() return {
    close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    show=function(_self,widget) confirmation=widget end,
    nextTick=function(_self,callback) callback() end,
} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,opts) return opts end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local opened={};local open_ok=true
package.preload['weread.ui.discovery_cache']=function() return {open=function(_host,query,cursor)
    opened[#opened+1]={query=query,cursor=cursor};return open_ok
end} end
local Saved=require('weread.ui.saved_searches')
local function entry(keyword) return {keyword=keyword,generation=string.rep('a',32)} end
local owner={};local account='account-a';local info,menu,cancelled=nil,nil,0
local worker={start=function(self,task,callback) self.task=task;self.callback=callback;return true end,
    cancel=function() cancelled=cancelled+1 end}
local host={shelf_view=owner,discovery_epoch=0,library_db={accountKey=function() return account end},
    settings={get=function() return {source='auto'} end},client={},saved_searches_worker=worker,
    showBusy=function(self) self.busy_message={} end,closeBusy=function(self) self.busy_message=nil end,
    showInfo=function(_self,text) info=text end,
    showList=function(_self,title,rows) menu={title=title,item_table=rows};return menu end}
expect(Saved.open(host) and host.saved_searches_job,'loading did not start')
worker.callback({ok=true,items={entry('First'),entry('Second')}})
expect(menu and menu.title=='Saved searches' and owner._shelf_popup==menu and #menu.item_table==2,'saved menu missing')
menu.item_table[2].callback()
expect(#opened==1 and opened[1].query.keyword=='Second' and opened[1].cursor==0 and not owner._shelf_popup,
    'selection did not open cached search')

expect(Saved.open(host));local late=worker.callback;account='account-b';late({ok=true,items={entry('Private')}})
expect(not host.saved_searches_job and #opened==1 and not host._discovery_menu,'account change exposed saved search')
account='account-a';expect(Saved.open(host));late=worker.callback;Saved.cancel(host);late({ok=true,items={entry('Late')}})
expect(not host._discovery_menu and cancelled>0,'cancelled worker reopened menu')
expect(Saved.open(host));worker.callback({ok=true,items={}})
expect(info=='No saved searches yet. Search online to save results.','empty cache did not explain next step')
for _,bad in ipairs({{ok=true,items={entry('x'),entry('x')}},{ok=true,items={[1]=entry('x'),[3]=entry('z')}},
    {ok=true,items={entry('bad\ntext')}},{ok=true,items={entry(string.char(255))}},
    {ok=true,items={{keyword='x',generation='bad'}}},{ok=false}}) do
    info=nil;expect(Saved.open(host));worker.callback(bad)
    expect(info=='Could not load saved searches.' and not host._discovery_menu,'invalid worker result was shown')
end
expect(Saved.open(host));worker.callback({ok=true,items={entry('Gone')}});open_ok=false;menu.item_table[1].callback()
expect(info=='This saved search is no longer available. Search again to refresh it.','removed cache was not handled')
open_ok=true
expect(Saved.open(host));worker.callback({ok=true,items={entry('First')}})
local other_account=menu.item_table[1].callback;account='account-b';other_account()
expect(#opened==2,'menu selection crossed an account change')
account='account-a';require('weread.ui.shelf_popup').close(owner)
local input={};owner._shelf_popup=input
expect(Saved.open(host,input));late=worker.callback;owner._shelf_popup=nil;late({ok=true,items={entry('Late')}})
expect(not host.saved_searches_job and not host._discovery_menu,'closed input accepted a late worker')
expect(Saved.open(host));worker.callback({ok=true,items={entry('First')}})
local stale=menu.item_table[1].callback;owner._shelf_closed=true;stale()
expect(#opened==2,'closed owner selected cached search')
owner._shelf_closed=nil;require('weread.ui.shelf_popup').close(owner)
expect(Saved.open(host));worker.callback({ok=true,items={entry('First')}})
menu:onMenuHold(menu.item_table[1]);expect(confirmation and confirmation.ok_callback,'hold did not open confirmation')
confirmation.cancel_callback();expect(not host.saved_searches_job,'cancel started deletion')
menu:onMenuHold(menu.item_table[1]);local dismissed=confirmation
require('ui/uimanager'):close(dismissed);menu:onMenuHold(menu.item_table[1])
expect(confirmation~=dismissed,'dismissing confirmation prevented reopening it')
confirmation.cancel_callback()
menu:onMenuHold(menu.item_table[1]);confirmation.ok_callback()
expect(host.saved_searches_job and worker.task and worker.callback,'confirmed deletion did not start worker')
worker.callback({status='deleted'});expect(host.saved_searches_job and not host._discovery_menu,'successful removal did not reload')
worker.callback({ok=true,items={entry('Second')}});expect(menu.item_table[1].text=='Second','reloaded searches were not shown')
menu:onMenuHold(menu.item_table[1]);confirmation.ok_callback();worker.callback({status='changed'})
expect(info=='This saved search changed. The updated results were kept.' and host.saved_searches_job,
    'changed entry did not preserve refreshed data')
worker.callback({ok=true,items={entry('Second')}})
menu:onMenuHold(menu.item_table[1]);confirmation.ok_callback();worker.callback({status='unavailable'})
expect(info=='Could not remove this saved search.' and not host.saved_searches_job and host._discovery_menu,
    'storage error lost the list or reported success')
menu:onMenuHold(menu.item_table[1]);local stale_confirm=confirmation;account='account-b';stale_confirm.ok_callback()
expect(not host.saved_searches_job,'confirmation crossed an account change')
account='account-a';menu:onMenuHold(menu.item_table[1]);stale_confirm=confirmation
require('weread.ui.shelf_popup').close(owner);stale_confirm.ok_callback()
expect(not host.saved_searches_job and not host._discovery_menu,'closed menu accepted stale confirmation')
expect(Saved.open(host));worker.callback({ok=true,items={entry('Second')}})
menu:onMenuHold(menu.item_table[1]);confirmation.ok_callback();local deletion=worker.callback
require('weread.ui.shelf_popup').close(owner);deletion({status='deleted'})
expect(not host.saved_searches_job and not host._discovery_menu,'closed menu accepted a late deletion result')
print('saved_searches_ui_spec: '..checks..' checks')
