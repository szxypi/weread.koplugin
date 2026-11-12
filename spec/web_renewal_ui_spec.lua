package.path='./?.lua;'..package.path
local state
package.preload['weread.lib.web_renewal']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['ui/uimanager']=function() return {show=function() end,close=function() state.closed=(state.closed or 0)+1 end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
local UI=require('weread.ui.web_renewal')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    state={callbacks={},results={},current=true,starts=0,cancels=0}
    local service={start=function(self,options,callback)
        state.starts=state.starts+1;self.job={is_current=options.is_current};state.callbacks[#state.callbacks+1]=callback
        if state.start_failed then self.job=nil;return false,'renewal_unconfirmed' end
        return true,self.job
    end,cancel=function(self,job) if self.job==job then self.job=nil;state.cancels=state.cancels+1 end end}
    local host={web_renewal=service,showBusy=function(self,_text,cancel) self.busy_message={};state.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end}
    local function done(ok,reason) state.results[#state.results+1]={ok=ok,reason=reason} end
    local function deliver(ok,reason,index) state.callbacks[index or #state.callbacks](ok,reason) end
    return host,done,deliver
end
local host,done,deliver=fixture();UI.run(host,{busy=true},done);deliver(true)
expect(#state.results==1 and state.results[1].ok and not host._web_renewal_request and not host.busy_message,'success did not finish/close owned loading')
host,done,deliver=fixture();UI.run(host,{busy=true},done);deliver(false,'save_failed')
local request=host._web_renewal_request;local dialog=request.dialog
expect(dialog and #state.results==0 and host.busy_message,'save failure did not offer receipt-only retry')
dialog.ok_callback();expect(state.starts==2,'retry did not resume service');deliver(true)
expect(#state.results==1 and state.results[1].ok and not host._web_renewal_request,'retry did not finish')
host,done,deliver=fixture();UI.run(host,{busy=true},done);deliver(false,'save_failed');host._web_renewal_request.dialog.cancel_callback()
expect(state.results[1].reason=='save_failed' and not host.busy_message,'declined save left job/loading active')
host,done,deliver=fixture();UI.run(host,{busy=true,is_current=function() return state.current end},done);state.current=false;deliver(true)
expect(#state.results==1 and state.results[1].reason=='session_changed' and not host.busy_message,'stale request kept caller waiting or reported success')
host,done,deliver=fixture();UI.run(host,{busy=true},done);state.cancel();deliver(true)
expect(#state.results==0 and not host._web_renewal_request and state.cancels==1,'cancelled request invoked old callback')
host,done,deliver=fixture();UI.run(host,{},done);local old=host._web_renewal_request;UI.cancel(host,old);UI.run(host,{},done)
local current=host._web_renewal_request;deliver(true,nil,1)
expect(host._web_renewal_request==current and #state.results==0,'old callback closed a newer request');deliver(true)
expect(#state.results==1 and state.results[1].ok,'new request lost result')
host,done=fixture();state.start_failed=true;UI.run(host,{busy=true},done)
expect(state.results[1].reason=='renewal_unconfirmed' and not host._web_renewal_request and not host.busy_message,'start failure kept busy UI')
host,done=fixture();UI.run(host,{},done);local ok,reason=UI.run(host,{},done)
expect(not ok and reason=='busy' and state.starts==1,'concurrent renewal replaced current owner')
print('PASS: shared Web renewal UI and receipt save confirmation ('..checks..' checks)')
