package.path='./?.lua;'..package.path
local UI={}
function UI:show(widget) self.top=widget end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
function UI:nextTick(callback) callback() end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,T=function(v) return v end} end
package.loaded['weread.ui.shelf_state']={show=function(host,id) host.shown=id end}
local Finish=require('weread.ui.finish_offline')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function fixture()
    local state={account='account',present=true,finished=false,online=false}
    local host={client={},ui={document={}},_shelf_state_menu={},library_db={}}
    function host.library_db:accountKey() return state.account end
    function host.library_db:open() end
    function host.library_db:getShelfStatus() return {present=state.present,book={finishReading=state.finished}} end
    function host:isNetworkConnected() return state.online end
    function host:showInfo(text) state.message=text end
    host._finish_offline_queue={
        get=function() return state.entry end,
        put=function(_self,id,before,desired)
            if state.entry then return nil end
            state.entry={book_id=id,before=before,desired=desired,phase='queued'};return state.entry
        end,
        remove=function(_self,record) if state.entry~=record then return false end;state.entry=nil;return true end,
    }
    return host,state
end
local host,s=fixture();expect(Finish.open(host,'41'),'offline action did not open')
expect(s.entry==nil,'offline action saved before confirmation')
UI.top.ok_callback();expect(s.entry and s.entry.before==false and s.entry.desired==true and host.shown=='41','offline intent was not saved')
expect(Finish.open(host,'41'),'queued action did not open');UI.top.ok_callback()
expect(s.entry==nil,'queued action could not be cancelled')
host,s=fixture();s.present=false;expect(not Finish.open(host,'41') and not s.entry,'absent book treated as unfinished')
host,s=fixture();s.finished=nil;expect(not Finish.open(host,'41') and not s.entry,'unknown finished mark guessed')
host,s=fixture();Finish.open(host,'41');local stale=UI.top;s.finished=true;stale.ok_callback()
expect(not s.entry and s.message:find('Could not save',1,true),'changed cached status allowed stale intent')
host,s=fixture();Finish.open(host,'41');stale=UI.top;s.account='other';stale.ok_callback()
expect(not s.entry,'old account created intent')
host,s=fixture();Finish.open(host,'41');stale=UI.top;UI:close(stale);stale.ok_callback()
expect(not s.entry,'closed confirmation created intent')
host,s=fixture();s.entry={book_id='41',before=false,desired=true,phase='dispatching'}
package.loaded['weread.ui.finish_change']={pending=function() return {phase='pending'} end}
expect(not Finish.open(host,'41') and s.entry,'possible dispatch removed while write journal pending')
package.loaded['weread.ui.finish_change']={pending=function() end}
expect(Finish.open(host,'41'),'orphaned claim could not be reviewed')
expect(UI.top.text:find('may have been sent',1,true),'orphaned claim omitted uncertainty warning')
UI.top.ok_callback();expect(not s.entry,'explicit orphan cleanup failed')
print('finish_offline_ui_spec: '..checks..' checks')
