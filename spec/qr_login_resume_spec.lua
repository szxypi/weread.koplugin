package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local queue={}
package.preload['device']=function() return {screen={}} end
package.preload['weread.lib.i18n']=function() return {tr=function(value) return value end} end
package.preload['ui/widget/inputdialog']=function() return {} end
package.preload['ui/widget/qrmessage']=function() return {} end
package.preload['ffi/util']=function() return {template=function(value) return value end} end
package.preload['weread.lib.logger']=function() return {scoped=function() return {info=function() end,err=function() end} end} end
package.preload['ui/uimanager']=function() return {nextTick=function(_self,fn) queue[#queue+1]=fn end} end
local QR=require('weread.lib.qr_login')
local function fixture()
    queue={}
    local state={current=true,scope={vid='123',epoch=1},cookie=true,resumes=0,info=0}
    local settings={get_auth_scope=function() return state.scope end,
        auth_scope_matches=function(_self,scope) return scope==state.scope end,
        is_cookie_configured=function() return state.cookie end,is_api_configured=function() return false end}
    local host={settings=settings,discovery_epoch=1,ui={},showBusy=function() end,closeBusy=function() end,
        runOnlineTask=function(_self,_label,fn) fn() end,refreshLoginMenu=function() end,
        showTransientInfo=function() end,showInfo=function() state.info=state.info+1 end,
        safeCallback=function(_self,_label,callback) return callback end}
    local login=QR:new(host,{},settings)
    login._complete_protocol=function() return {name='Synthetic'} end
    login.continuation={current=function() return state.current end,resume=function() state.resumes=state.resumes+1 end}
    return login,host,state
end
local login,_,state=fixture();login:_complete({},login.generation)
expect(#queue==1 and state.resumes==0 and state.info==0,'successful login did not defer reading')
queue[1]();queue[1]()
expect(state.resumes==1,'login continuation did not run exactly once')
for _,change in ipairs({'cancel','account','epoch','document','view','cookie'}) do
    local host
    login,host,state=fixture();login:_complete({},login.generation)
    if change=='cancel' then login:cancel()
    elseif change=='account' then state.scope={vid='456',epoch=2}
    elseif change=='epoch' then host.discovery_epoch=2
    elseif change=='document' then host.ui.document={}
    elseif change=='view' then host.shelf_view={}
    else state.cookie=false end
    queue[1]();expect(state.resumes==0,'stale login continued after '..change)
end
login,_,state=fixture();state.current=false;login:_complete({},login.generation)
expect(#queue==0 and state.info==1 and state.resumes==0,'stale read intent was resumed')
login,_,state=fixture();login._complete_protocol=function() error('synthetic failure') end
login:_complete({},login.generation)
expect(#queue==0 and state.info==1 and not login.continuation,'failed login retained a continuation')
local host
login,host,state=fixture()
host.isNetworkOnline=function() return true end
login._begin_protocol=function() error('synthetic UID failure') end
login:start(login.continuation)
expect(not login.continuation and state.info==1,'failed QR preparation retained a continuation')
login,host,_=fixture();host.isNetworkOnline=function() return true end
host.runOnlineTask=function() return false end
login:start(login.continuation)
expect(not login.continuation,'offline task scheduling retained a continuation')
login,host,_=fixture();host.isNetworkOnline=function() return false end;host.showOffline=function() end
login:start(login.continuation)
expect(not login.continuation,'offline QR restart retained an old continuation')
login,host,_=fixture();local closed=0
host.runOnlineTask=function() return false end;host.closeBusy=function() closed=closed+1 end
login:_complete({},login.generation)
expect(not login.continuation and closed==1,'offline login completion retained the reading intent or spinner')
print('qr_login_resume_spec: '..checks..' checks')
