package.path='./?.lua;./?/init.lua;'..package.path
local n=0;local function expect(value,message) n=n+1;assert(value,message or ('check '..n)) end
package.preload['ui/uimanager']=function() return {close=function() end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
local shown
package.preload['weread.ui.read_stats_view']=function() return {show=function(data,callbacks)
    shown={data=data,callbacks=callbacks};return shown
end} end
local Name=require('weread.lib.profile_account');local Profile=require('weread.ui.profile')
local account,epoch,revision,online='a',1,1,true
local scope=function() return {vid=account=='a' and '123' or '456',epoch=epoch} end
Name.capture=function() return {web={},revision=revision} end
Name.matches=function(_settings,access) return access.revision==revision end
Name.fetch=function() return 'Updated' end
local states,tasks,writes,fail={}, {},0,false
local worker={start=function(self,task,callback)
    self.active={task=task,callback=callback};tasks[#tasks+1]=self.active;return true
end,cancel=function(self) self.cancelled=self.active end}
local host=setmetatable({
    settings={get_auth_scope=scope,get=function(_self,key,default)
        if key=='account' then return {user_vid=scope().vid,name='QR name'} end
        return default
    end},
    library_db={accountKey=function() return account end,getProfileOverview=function()
        local current=states[account] or {}
        return current.statistics,current.goal,current.account_name
    end,putProfileState=function(_self,key,value)
        if fail then return false end;states[account]=states[account] or {};states[account][key]=value;writes=writes+1;return true
    end},
    profile_name_worker=worker,client={},isNetworkConnected=function() return online end,
    isNetworkOnline=function() error('profile nickname refresh probed the Internet on the UI thread') end,
    discoveryNavigation=function() return {} end,refreshProfile=function() end,closeWeReadUI=function(self) self:cancelProfileRefresh() end,
},{__index=Profile})
host:showProfile();expect(shown.data.account_name=='QR name')
shown.callbacks.on_refresh();expect(#tasks==1 and host.profile_name_request,'manual refresh did not start')
host:refreshProfileName();expect(#tasks==1,'duplicate refresh started')
tasks[1].callback(tasks[1].task());expect(writes==1 and shown.data.account_name=='Updated','verified name not displayed')
expect(states.a.account_name.name=='Updated' and states.a.account_name.epoch==1,'name was not saved for the login')
online=false;host:showProfile();expect(shown.data.account_name=='Updated','offline reopen lost name')
host:refreshProfileName();expect(#tasks==1,'offline refresh started');online=true
host:refreshProfileName();local pending=tasks[#tasks];account='b';pending.callback({name='Wrong'})
expect(writes==1 and not states.b,'name crossed accounts');account='a'
host:refreshProfileName();pending=tasks[#tasks];revision=2;pending.callback({name='Stale'})
expect(writes==1 and not host.profile_name_request,'old cookie result was saved')
host:refreshProfileName();pending=tasks[#tasks];epoch=2;pending.callback({name='Stale'})
expect(writes==1,'old login result was saved')
host:showProfile();expect(shown.data.account_name=='QR name','old cache replaced newer QR login')
host:refreshProfileName();pending=tasks[#tasks];host:cancelProfileRefresh();pending.callback({name='Stale'})
expect(worker.cancelled==pending and writes==1,'cancelled request saved')
host:refreshProfileName();pending=tasks[#tasks];fail=true;pending.callback({name='Failed'})
expect(writes==1 and shown.data.account_name=='QR name','failed persistence changed the display');fail=false
host:refreshProfileName();pending=tasks[#tasks];host._profile_goal_dialog={};local behind=shown
pending.callback({name='Current'});expect(writes==2 and shown==behind,'refresh covered goal dialog')
host._profile_goal_dialog=nil;host:showProfile();expect(shown.data.account_name=='Current','name not shown after dialog closed')
print('profile_account_ui_spec: '..n..' checks')
