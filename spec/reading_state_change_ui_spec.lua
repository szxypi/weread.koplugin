package.path='./?.lua;'..package.path
local UI={}
function UI:show(widget) self.shown=widget end
function UI:close(_widget) end
package.loaded['ui/uimanager']=UI
package.loaded['ui/widget/confirmbox']={new=function(_,options) return options end}
package.loaded['ffi/util']={template=function(value,arg) return (value:gsub('%%1',function() return tostring(arg) end)) end}
package.loaded['weread.lib.plugin_util']={tr=function(value) return value end}
package.loaded['weread.ui.offline_paused']={wake=function() end}
local shelf_open=0
package.loaded['weread.ui.shelf_state']={show=function() shelf_open=shelf_open+1 end}
package.loaded['weread.ui.finish_offline']={cancel_sync=function() end}
package.loaded['weread.ui.membership_offline']={cancel_sync=function() end}
local other_pending,other_error
package.loaded['weread.ui.finish_change']={pending=function() return other_pending,other_error end,cancel=function() end}
package.loaded['weread.ui.shelf_flag_change']={pending=function() return other_pending,other_error end,cancel=function() end}
local reading_cancelled=0
package.loaded['weread.ui.reading_state']={cancel=function() reading_cancelled=reading_cancelled+1 end}
local Change=require('weread.ui.reading_state_change')
local function fixture()
    other_pending,other_error=nil,nil
    local state={account='one',notices={},commits=0,accepted=0,cancelled=0,online=true}
    local service={last_snapshot={books={},archive={}}}
    function service:pending() return state.pending,state.error end
    function service:cancel() state.cancelled=state.cancelled+1 end
    function service:prepare(id,guard,callback,resolving)
        state.id,state.guard,state.prepared,state.resolving=id,guard,callback,resolving;return true
    end
    function service:preview_current(plan) return state.plan==plan and state.guard() end
    function service:commit(_plan,callback) state.commits=state.commits+1;state.committed=callback;return true end
    function service:accept_current(_plan) state.accepted=state.accepted+1;return true end
    local host={client={},settings={},_reading_state_change_service=service,_reader_session_gen=1,
        _shelf_state_menu={},_book_detail_view={},ui={document={}},library_db={open=function() end,
            accountKey=function() return state.account end,getBook=function() return {title='Synthetic'} end},
        isNetworkConnected=function() return state.online end,
        showInfo=function(_self,text) state.notices[#state.notices+1]=text end,
        showOffline=function() state.offline=true end,
        showBusy=function(self,_text,cancel) self.busy_message={cancel=cancel} end,
        closeBusy=function(self) self.busy_message=nil end,
        applyShelfSnapshot=function() state.applied=true end}
    return host,state
end
local host,state=fixture();assert(Change.open(host,'41'))
assert(reading_cancelled>0 and state.id=='41' and host.busy_message)
state.plan={metadata={book_id='41',desired=true},resolving=false};state.prepared(state.plan)
local dialog=host._reading_state_change_ui.dialog
assert(dialog.ok_text=='Mark as started' and dialog.text:find('Synthetic',1,true))
dialog.ok_callback();assert(state.commits==1 and host.busy_message)
state.committed({kind='confirmed'},true)
assert(state.applied and not host._reading_state_change_ui and not host.busy_message
    and state.notices[1]=='The current started-reading status was verified in WeRead.')
state.committed({kind='confirmed'},true);assert(#state.notices==1,'duplicate completion rendered')
host,state=fixture();assert(Change.open(host,'CB_abc'))
state.plan={metadata={book_id='CB_abc',desired=false},resolving=false};state.prepared(state.plan)
dialog=host._reading_state_change_ui.dialog;assert(dialog.ok_text=='Mark as not started');dialog.ok_callback()
state.committed({kind='unconfirmed'},false)
assert(state.notices[1]=='The started-reading change is unconfirmed. It will not be sent again automatically.')
host,state=fixture();assert(Change.open(host,'41'))
state.plan={metadata={book_id='41',desired=true},resolving=false};state.prepared(state.plan)
dialog=host._reading_state_change_ui.dialog;state.account='other';dialog.ok_callback()
assert(state.commits==0,'stale account dispatched')
Change.cancel(host)
host,state=fixture();state.pending={phase='pending'}
assert(Change.open(host,'41',true) and state.resolving)
state.plan={metadata={book_id='41',desired=true},resolving=true,current_present=true,current_started=nil,position_unchanged=false}
state.prepared(state.plan);dialog=host._reading_state_change_ui.dialog
assert(dialog.text:find('did not provide',1,true) and dialog.text:find('position has changed',1,true))
dialog.ok_callback();assert(host._reading_state_change_ui.dialog~=dialog and state.commits==0)
host._reading_state_change_ui.dialog.ok_callback()
assert(state.accepted==1 and state.commits==0 and state.applied)
host,state=fixture();other_pending={phase='pending'}
assert(not Change.open(host,'41') and not state.prepared and #state.notices==1)
host,state=fixture();other_error='storage'
assert(not Change.open(host,'41') and not state.prepared
    and state.notices[1]=='Could not check previous shelf changes. Check storage and try again.')
host,state=fixture();host.shelf_membership={pending=function() return {phase='pending'} end}
assert(not Change.open(host,'41') and not state.prepared)
host,state=fixture();host.shelf_membership={pending=function() return nil,'storage' end}
assert(not Change.open(host,'41') and not state.prepared
    and state.notices[1]=='Could not check previous shelf changes. Check storage and try again.')
host,state=fixture();state.online=false
assert(not Change.open(host,'41') and state.offline and not state.prepared)
host,state=fixture();state.pending={phase='pending'}
assert(Change.block(host) and #state.notices==1)
host,state=fixture();state.error='storage';assert(Change.block(host)
    and state.notices[1]=='Could not check previous started-reading changes. Check storage and try again.')
host=fixture();assert(not Change.block(host))
assert(shelf_open>0)
print('PASS: started-reading change UI, pending review and ownership')
