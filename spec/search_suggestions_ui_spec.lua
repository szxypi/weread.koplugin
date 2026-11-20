package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
package.preload['ui/uimanager']=function() return {
    close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    nextTick=function(_self,callback) callback() end,
} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local selected={native={scope={vid='123'},credentials={},revision=1},revision='first',base_revision='base'}
local valid_access=true
package.preload['weread.lib.native_gateway_access']=function() return {
    capture=function() return selected end,matches=function() return valid_access end} end
local cancelled=0;local recovery_mode=false;local recovery
package.preload['weread.lib.native_read_recovery']=function() return {
    current=function() return valid_access end,cancel=function() end,start=function(_host,job,_selected,options)
        if not recovery_mode or job.recovery_attempted then return false end
        job.recovery_attempted=true;job.renewing=true;recovery={job=job,options=options};return true
    end} end
local Model=require('weread.lib.search_suggestions')
local fetches=0
Model.fetch=function(_client,_selected,keyword) fetches=fetches+1;return {keyword..' one',keyword..' two'} end
local Suggestions=require('weread.ui.search_suggestions')
local owner={};local input={value='term'};owner._shelf_popup=input
function input:getInputText() return self.value end
local account='account';local info,menu,opened,edited,online=nil,nil,nil,nil,true;local edit_calls=0
local worker={start=function(self,task,callback) self.task=task;self.callback=callback;return true end,
    cancel=function() cancelled=cancelled+1 end}
local host={shelf_view=owner,discovery_epoch=0,library_db={accountKey=function() return account end},
    settings={get=function() return {source='auto'} end},client={},search_suggestions_worker=worker,
    isNetworkOnline=function() return online end,showOffline=function() info='offline' end,
    showBusy=function(self,_message,cancel) self.busy_message={cancel=cancel} end,
    closeBusy=function(self) self.busy_message=nil end,showInfo=function(_self,text) info=text end,
    showList=function(_self,title,rows) menu={title=title,item_table=rows};return menu end,
    loadDiscoveryBatch=function(_self,kind,keyword,cursor) opened={kind,keyword,cursor} end,
    showDiscoverySearch=function(_self,keyword) edited=keyword;edit_calls=edit_calls+1 end}
expect(Suggestions.open(host,input) and host.search_suggestions_job,'request not started')
worker.callback(worker.task())
expect(menu and owner._shelf_popup==menu and #menu.item_table==4 and menu.item_table[3].text=='term one',
    'suggestions menu missing')
menu.item_table[4].callback()
expect(opened and opened[1]=='search' and opened[2]=='term two' and opened[3]==0,'selection did not search')
owner._shelf_popup=input;expect(Suggestions.open(host,input));worker.callback({ok=true,words={'choice'}})
menu.item_table[1].callback()
expect(opened[1]=='search' and opened[2]=='term','original search text was lost')
owner._shelf_popup=input;expect(Suggestions.open(host,input));worker.callback({ok=true,words={'choice'}})
menu.item_table[2].callback()
expect(edited=='term','editing did not recover the entered search text')
owner._shelf_popup=input;expect(Suggestions.open(host,input));worker.callback({ok=true,words={'choice'}})
local stale_edit=menu.item_table[2].callback;account='other';stale_edit()
expect(edited=='term' and edit_calls==1 and owner._shelf_popup==menu,'old edit action crossed accounts')
account='account';require('weread.ui.shelf_popup').close(owner)
owner._shelf_popup=input;input.value='term';expect(Suggestions.open(host,input));local late=worker.callback
input.value='changed';late({ok=true,words={'stale'}})
expect(not host.search_suggestions_job and not host._discovery_menu,'edited query accepted stale result')
input.value='term';expect(Suggestions.open(host,input));late=worker.callback;account='other';late({ok=true,words={'private'}})
expect(not host.search_suggestions_job and not host._discovery_menu,'account change accepted stale result')
account='account';expect(Suggestions.open(host,input));late=worker.callback;Suggestions.cancel(host);late({ok=true,words={'late'}})
expect(not host._discovery_menu and cancelled>0,'cancel did not invalidate worker')
expect(Suggestions.open(host,input));worker.callback({ok=true,words={}})
expect(info=='No search suggestions found.' and owner._shelf_popup==input,'empty response replaced input')
expect(Suggestions.open(host,input));worker.callback({ok=true,words={'a','a'}})
expect(info=='Could not load search suggestions.','duplicate worker response accepted')
recovery_mode=true;expect(Suggestions.open(host,input));worker.callback({ok=false,expired=true})
expect(recovery and host.search_suggestions_job==recovery.job and recovery.options.is_current(),
    'expired request did not start scoped recovery')
recovery.job.renewing=nil;recovery.options.complete(true,selected)
expect(host.search_suggestions_job==recovery.job,'successful renewal did not retry')
worker.callback({ok=false,expired=true})
expect(not host.search_suggestions_job and info=='Could not load search suggestions.',
    'repeated expiration retried indefinitely')
recovery_mode=false
online=false;expect(not Suggestions.open(host,input) and info=='offline','offline request attempted');online=true
input.value='  ';expect(not Suggestions.open(host,input) and info=='Enter a search term first.','empty query accepted')
input.value='term';selected={native=nil};expect(not Suggestions.open(host,input)
    and info=='Search suggestions need E-Ink authorization.','missing native authorization accepted')
expect(fetches==1,'unexpected request count')
print('search_suggestions_ui_spec: '..checks..' checks')
