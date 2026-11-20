package.path='./?.lua;'..package.path
local UI={tasks={}}
function UI:nextTick(fn) self.tasks[#self.tasks+1]=fn end
function UI:drain() while #self.tasks>0 do table.remove(self.tasks,1)() end end
function UI:show(widget) self.top=widget end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
function UI:unschedule() end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,T=function(v) return v end} end
package.loaded['weread.ui.finish_change']={service=function() return {} end,pending=function() end}
package.loaded['weread.ui.shelf_flag_change']={pending=function() end}
package.loaded['weread.ui.shelf_state']={show=function() end}
local last_finish,last_member,pump_result
package.loaded['weread.lib.finish_queue_sync']={new=function(_,options)
    last_finish={options=options,pumps=0};function last_finish:pump() self.pumps=self.pumps+1;return pump_result end
    function last_finish:cancel() self.job=nil end;return last_finish
end}
package.loaded['weread.lib.membership_queue_sync']={new=function(_,options)
    last_member={options=options,pumps=0};function last_member:pump() self.pumps=self.pumps+1;return pump_result end
    function last_member:cancel() self.job=nil end;return last_member
end}
local Finish=require('weread.ui.finish_offline')
local Member=require('weread.ui.membership_offline')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function fixture(kind,claimed)
    UI.tasks={};last_finish,last_member,pump_result=nil,nil,true
    local s={account='one',online=true,entry={book_id='41',id='token',phase=claimed and 'dispatching' or 'queued'}}
    local host={library_db={},client={},shelf_membership={}}
    function host.library_db:accountKey() return s.account end
    function host.library_db:open() end
    function host.library_db:getShelfStatus() return {present=true,book={finishReading=0}} end
    function host:isNetworkConnected() return s.online end
    function host:showInfo() end
    function host.shelf_membership:pending() return nil end
    local store={get=function() return s.entry,s.error end,
        remove=function(_,record) if record~=s.entry then return false end;s.entry=nil;return true end}
    local sync={job={entry=s.entry,claim=claimed and s.entry or nil},cancel=function(self) self.job=nil end}
    if kind=='finish' then
        host._finish_offline_queue=store;host._finish_offline_sync=sync;host._finish_offline_account='one'
    else
        host._membership_offline_queue=store;host._membership_offline_sync=sync;host._membership_offline_account='one'
    end
    return host,s
end
for _,kind in ipairs({'finish','membership'}) do
    local module=kind=='finish' and Finish or Member
    local host=fixture(kind)
    module.cancel_sync(host,true)
    expect(module.open(host,'41'),'dialog did not open: '..kind)
    UI:drain();expect(not last_finish and not last_member,'request resumed with dialog open: '..kind)
    UI.top.cancel_callback();UI:drain()
    local active=kind=='finish' and last_finish or last_member
    expect(active and active.pumps==1,'paused read did not resume after closing: '..kind)
    UI:drain();expect(active.pumps==1,'paused read resumed more than once: '..kind)
    for _,change in ipairs({'account','token','dispatching','storage','cancel'}) do
        local s;host,s=fixture(kind);module.cancel_sync(host,true);expect(module.open(host,'41'),'guard dialog did not open')
        UI:drain()
        if change=='account' then s.account='two'
        elseif change=='token' then s.entry.id='new'
        elseif change=='dispatching' then s.entry.phase='dispatching'
        elseif change=='storage' then s.error='storage'
        else module.cancel_sync(host) end
        UI.top.cancel_callback();UI:drain()
        expect(not last_finish and not last_member,'unsafe paused read resumed: '..kind..' '..change)
    end
    host=fixture(kind,true);module.cancel_sync(host,true);UI:drain()
    expect(not last_finish and not last_member,'possibly sent write resumed: '..kind)
    host=fixture(kind)
    local sync=kind=='finish' and host._finish_offline_sync or host._membership_offline_sync
    sync.job.claim={};module.cancel_sync(host,true);UI:drain()
    expect(not last_finish and not last_member,'claim was treated as an unsent read: '..kind)
    host=fixture(kind);module.cancel_sync(host,true);expect(module.open(host,'41'),'removal dialog did not open')
    UI:drain();UI.top.ok_callback();UI:drain()
    expect(not last_finish and not last_member,'removed offline intent was resumed: '..kind)
    host=fixture(kind);module.cancel_sync(host,true);UI:drain()
    local resumed=kind=='finish' and last_finish or last_member
    expect(resumed and resumed.pumps==1,'early exit did not resume cancelled preparation: '..kind)
    host=fixture(kind);pump_result=false;module.cancel_sync(host,true);UI:drain()
    resumed=kind=='finish' and last_finish or last_member
    require('weread.ui.offline_paused').wake(host);UI:drain()
    expect(resumed and resumed.pumps==1,'failed preparation was retried repeatedly: '..kind)
end
local host=fixture('finish');host._finish_offline_retry={timer=function() end}
Finish.cancel_sync(host,true);UI:drain()
expect(not last_finish,'interrupted preparation bypassed a pending backoff')
host._finish_offline_retry.timer=nil;require('weread.ui.offline_paused').wake(host);UI:drain()
expect(last_finish and last_finish.pumps==1,'preparation did not resume after backoff')
print('offline_paused_sync_spec: '..checks..' checks')
