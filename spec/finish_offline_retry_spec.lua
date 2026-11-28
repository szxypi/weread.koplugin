package.path='./?.lua;'..package.path
local scheduled,unscheduled={},{}
local UI={}
function UI:scheduleIn(delay,fn) scheduled[#scheduled+1]={delay=delay,fn=fn} end
function UI:unschedule(fn) unscheduled[fn]=true end
function UI:nextTick(fn) fn() end
function UI:show(widget) self.shown=widget end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,options) return options end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,T=function(v) return v end} end
package.loaded['weread.ui.shelf_flag_change']={pending=function() end}
package.loaded['weread.ui.reading_state_change']={pending=function() end,cancel=function() end,block=function() return false end}
package.loaded['weread.ui.finish_change']={service=function() return {} end}
local active
package.loaded['weread.lib.finish_queue_sync']={new=function(_self,options)
    active={options=options,pumps=0,cancels=0}
    function active:pump() self.pumps=self.pumps+1;return true end
    function active:cancel() self.cancels=self.cancels+1 end
    return active
end}
local Finish=require('weread.ui.finish_offline')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    scheduled,unscheduled={},{}
    local state={account='one',online=true,entry={book_id='41',id='token',phase='queued'},notices={}}
    local host={client={},library_db={}}
    function host.library_db:accountKey() return state.account end
    function host.library_db:open() end
    function host.library_db:getShelfStatus() return {present=true,book={finishReading=0}} end
    function host:isNetworkConnected() return state.online end
    function host:showTransientInfo(text) state.notices[#state.notices+1]=text end
    host._finish_offline_queue={get=function() return state.entry,state.error end}
    expect(Finish.pump(host),'initial pump did not start')
    return host,state,active
end
local host,state,sync=fixture();sync.options.notify('retryable',state.entry)
expect(#scheduled==1 and scheduled[1].delay==30,'first temporary failure did not schedule bounded retry')
expect(not Finish.pump(host) and sync.pumps==1,'another trigger bypassed the retry delay')
scheduled[1].fn();expect(sync.pumps==2,'queued intent was not retried')
sync.options.notify('retryable',state.entry)
expect(#scheduled==2 and scheduled[2].delay==60,'second temporary failure did not back off')
scheduled[2].fn();expect(sync.pumps==3,'second retry did not run')
sync.options.notify('retryable',state.entry)
expect(#scheduled==2 and #state.notices==1 and not host._finish_offline_retry.timer,'retry limit did not stop polling')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);local forced=scheduled[1].fn
host._finish_change_ui={}
expect(not Finish.pump(host,true) and host._finish_offline_retry.timer==forced and not unscheduled[forced],
    'blocked manual refresh discarded its scheduled retry')
host._finish_change_ui=nil
expect(Finish.pump(host,true) and unscheduled[forced] and sync.pumps==2,'explicit refresh did not resume queued work')
forced();expect(sync.pumps==2,'cancelled timer repeated an explicit refresh')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);local old=scheduled[1].fn
Finish.cancel_sync(host);old()
expect(unscheduled[old] and sync.cancels==1 and sync.pumps==1,'cancelled timer dispatched')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
state.account='two';old();expect(sync.pumps==1 and not host._finish_offline_retry,'old account retry dispatched')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
state.error='storage';old();expect(sync.pumps==1 and not host._finish_offline_retry,'unreadable queue triggered a retry')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
sync.options.notify('unconfirmed',state.entry);old()
expect(unscheduled[old] and sync.pumps==1 and not host._finish_offline_retry,'uncertain write retained an automatic retry')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
state.entry={book_id='41',id='new-token',phase='queued'};old()
expect(sync.pumps==2 and not host._finish_offline_retry,'changed intent was retried under stale timer')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
state.online=false;old();expect(sync.pumps==1 and host._finish_offline_account=='one','offline timer started a network operation')
for _,reason in ipairs({'login','rate_limited'}) do
    host,state,sync=fixture();sync.options.notify(reason,state.entry)
    expect(#scheduled==0 and #state.notices==1 and host._finish_offline_account=='one','non-retryable failure lacked guidance: '..reason)
end
host,state,sync=fixture();sync.options.notify('retryable',state.entry);scheduled[1].fn()
sync.options.notify('rate_limited',state.entry)
expect(#scheduled==1 and not host._finish_offline_retry.timer and #state.notices==1,
    'rate limiting after a retry scheduled further network traffic')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
Finish.cancel_sync(host,true)
expect(host._finish_offline_retry and host._finish_offline_retry.timer==old and not unscheduled[old],
    'opening a shelf action discarded the pending retry')
expect(Finish.open(host,'41'),'saved change dialog did not open')
old();expect(not host._finish_offline_retry.timer and host._finish_offline_retry.waiting_ui,
    'retry due during the dialog was not retained')
UI.shown.cancel_callback()
expect(active~=sync and active.pumps==1 and not host._finish_offline_retry.waiting_ui,
    'closing the dialog did not resume its due retry')
host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
Finish.cancel_sync(host,true);expect(Finish.open(host,'41'),'second dialog did not open')
UI.shown.cancel_callback()
expect(host._finish_offline_retry.timer==old and not unscheduled[old] and active==sync,
    'closing a dialog early bypassed the original delay')
old();expect(active~=sync and active.pumps==1,'original timer did not resume after early close')
for _,change in ipairs({'account','token','dispatching','storage','cancel'}) do
    host,state,sync=fixture();sync.options.notify('retryable',state.entry);old=scheduled[1].fn
    Finish.cancel_sync(host,true);expect(Finish.open(host,'41'),'guard test dialog did not open')
    old();expect(host._finish_offline_retry.waiting_ui,'guard test timer was not held')
    if change=='account' then state.account='two'
    elseif change=='token' then state.entry.id='new-token'
    elseif change=='dispatching' then state.entry.phase='dispatching'
    elseif change=='storage' then state.error='storage'
    else Finish.cancel_sync(host) end
    UI.shown.cancel_callback()
    expect(active==sync and not host._finish_offline_retry,'stale or unsafe retry resumed: '..change)
end
print('finish_offline_retry_spec: '..checks..' checks')
