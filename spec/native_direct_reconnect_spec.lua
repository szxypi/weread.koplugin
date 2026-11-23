package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local tasks,shown,closed={},nil,0
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_,_,task) tasks[#tasks+1]=task end,
    unschedule=function(_,task) for i=#tasks,1,-1 do if tasks[i]==task then table.remove(tasks,i) end end end,
    show=function(_,dialog) shown=dialog end,
    close=function(_,dialog) closed=closed+1;if shown==dialog then shown=nil end end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,options) return options end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,file) return file=='/native.epub' end} end
package.preload['weread.lib.native_position_contract']=function() return {account_key=function(vid) return vid=='123' and 'owner' end} end
local page=1
package.preload['weread.lib.source_context']=function() return {
    location=function() return {xpointer='xp'..page,page=page,pos=0,view_mode='page'} end,
    same_location=function(a,b) return a and b and a.xpointer==b.xpointer end,
} end
local invoked
package.preload['weread.ui.native_direct_navigation']=function() return {open_position=function(_,action) invoked=action end} end
local Reconnect=require('weread.ui.native_direct_reconnect')
local function fixture(connected,enabled)
    tasks={};shown=nil;closed=0;invoked=nil;page=1
    local state={online=connected,enabled=enabled,account='owner',scope={vid='123',epoch=1}}
    local host={ui={document={file='/native.epub'},view={view_mode='page'}},_reader_session_gen=1,
        library_db={accountKey=function() return state.account end},
        settings={get_auth_scope=function() return state.scope end,auth_scope_matches=function(_,scope) return state.scope==scope end,
            get=function() return {pull_on_open=state.enabled} end},isNetworkConnected=function() return state.online end}
    return host,state
end
local function pump() local task=table.remove(tasks,1);assert(task);task() end
local host,s=fixture(true,true);expect(Reconnect.ready(host),'ready failed');Reconnect.disconnected(host);s.online=false
page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);Reconnect.connected(host)
expect(#tasks==1 and not shown,'duplicate connection did not deduplicate');pump()
expect(shown and #shown.buttons==3 and not invoked,'offline change did not show the choice')
shown.buttons[1][1].callback();expect(invoked=='cloud' and not shown,'cloud comparison was not selected')
host,s=fixture(false,true);expect(Reconnect.ready(host));page=3;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
shown.buttons[2][1].callback();expect(invoked=='upload','manual position upload was not selected')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
shown.buttons[3][1].callback();expect(not invoked and not shown,'later triggered a position action')
host,s=fixture(false,false);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host)
expect(#tasks==0,'disabled automatic pull displayed a reconnect prompt')
host,s=fixture(false,true);Reconnect.ready(host);s.online=true;Reconnect.connected(host)
expect(#tasks==0,'unchanged page displayed a reconnect prompt')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);page=1;Reconnect.view_changed(host)
s.online=true;Reconnect.connected(host);expect(#tasks==0,'returning to the original page displayed a prompt')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
local callback=shown.buttons[2][1].callback;page=3;Reconnect.view_changed(host);callback()
expect(not invoked and not shown and closed==1,'stale page could trigger an upload')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
callback=shown.buttons[2][1].callback;s.account='other';callback();expect(not invoked,'stale account could trigger an upload')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
callback=shown.buttons[1][1].callback;s.online=false;callback();expect(not invoked,'offline confirmation started a cloud request')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);host._weread_suspended=true;s.online=true
Reconnect.connected(host);expect(#tasks==0,'prompt appeared during suspend');host._weread_suspended=nil;Reconnect.connected(host);pump()
expect(shown~=nil,'reconnection during suspend was not offered after resume')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host)
Reconnect.cancel(host);expect(#tasks==0 and not host._native_direct_reconnect,'closing did not cancel pending reminder')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
Reconnect.suspend(host);host._weread_suspended=true;expect(not shown,'suspend left the reminder open')
host._weread_suspended=nil;Reconnect.connected(host);pump();expect(shown~=nil,'suspend lost the unanswered reminder')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
callback=shown.buttons[2][1].callback;s.enabled=false;callback();expect(not invoked,'disabled pull allowed an old reminder')
print('PASS: native offline reconnect choices and session guards ('..checks..' checks)')
