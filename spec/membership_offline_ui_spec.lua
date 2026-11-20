package.path='./?.lua;'..package.path
local UI={}
function UI:show(widget) self.top=widget end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
function UI:nextTick(callback) callback() end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
package.loaded['weread.ui.shelf_state']={show=function(host,id) host.shown=id end}
local Offline=require('weread.ui.membership_offline')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function fixture()
    local s={account='account',present=false,online=false}
    local host={client={},ui={document={}},_shelf_state_menu={},library_db={},shelf_membership={}}
    function host.library_db:accountKey() return s.account end
    function host.library_db:open() end
    function host.library_db:getShelfStatus() return {present=s.present} end
    function host:isNetworkConnected() return s.online end
    function host:showInfo(text) s.message=text end
    function host.shelf_membership:pending() return s.pending,s.pending_error end
    host._membership_offline_queue={
        get=function() return s.entry end,
        put=function(_self,id,before,desired)
            if s.entry then return nil end
            s.entry={book_id=id,before=before,desired=desired,phase='queued'};return s.entry
        end,
        remove=function(_self,record) if s.entry~=record then return false end;s.entry=nil;return true end,
    }
    return host,s
end
local host,s=fixture();expect(Offline.open(host,'41'),'offline add not offered')
expect(not s.entry,'offline action saved before confirmation');UI.top.ok_callback()
expect(s.entry and not s.entry.before and s.entry.desired and host.shown=='41','offline add not saved')
expect(Offline.open(host,'41'),'queued action not offered');UI.top.ok_callback();expect(not s.entry,'queued action not cancelled')
host,s=fixture();s.present=true;expect(Offline.open(host,'41'),'offline removal not offered');UI.top.ok_callback()
expect(s.entry and s.entry.before and not s.entry.desired,'offline removal not saved')
host,s=fixture();s.present=nil;expect(not Offline.open(host,'41') and not s.entry,'unknown membership guessed')
host,s=fixture();function host.library_db:getShelfStatus() return false end
expect(not Offline.open(host,'41') and not s.entry,'malformed snapshot treated as absence')
host,s=fixture();function host.library_db:getShelfStatus() error('unavailable') end
expect(not Offline.open(host,'41') and not s.entry,'unreadable snapshot treated as absence')
host,s=fixture();Offline.open(host,'41');local stale=UI.top;s.present=true;stale.ok_callback()
expect(not s.entry and s.message:find('Could not save',1,true),'changed cached membership accepted')
host,s=fixture();Offline.open(host,'41');stale=UI.top;s.account='other';stale.ok_callback();expect(not s.entry,'old account created intent')
host,s=fixture();Offline.open(host,'41');stale=UI.top;UI:close(stale);stale.ok_callback();expect(not s.entry,'closed confirmation created intent')
host,s=fixture();s.entry={book_id='41',phase='dispatching'};s.pending=true
expect(not Offline.open(host,'41') and s.entry,'pending journal ignored');s.pending=false
expect(Offline.open(host,'41') and UI.top.text:find('may have been sent',1,true),'uncertain request lacks warning')
UI.top.ok_callback();expect(not s.entry,'explicit orphan removal failed')
print('membership_offline_ui_spec: '..checks..' checks')
