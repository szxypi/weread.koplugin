package.path='./?.lua;'..package.path
local ticks={};local UI={}
function UI:nextTick(callback) ticks[#ticks+1]=callback end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.loaded['weread.ui.finish_change']={pending=function() return nil end}
package.loaded['weread.ui.shelf_flag_change']={pending=function() return nil end}
package.loaded['weread.ui.reading_state_change']={pending=function() end,cancel=function() end,block=function() return false end}
local options
package.preload['weread.lib.membership_queue_sync']=function() return {new=function(_self,value)
    options=value;return {pump=function() return true end}
end} end
local Offline=require('weread.ui.membership_offline')
local Popup=require('weread.ui.shelf_popup')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function drain() while #ticks>0 do local pending=ticks;ticks={};for _,callback in ipairs(pending) do callback() end end end
local function fixture()
    local state={account='one',applied=0,redraws=0}
    local view={};local host={shelf_view=view,library_db={},client={},shelf_membership={},_membership_offline_queue={}}
    function host.library_db:accountKey() return state.account end
    function host.library_db:open() end
    function host.library_db:cacheShelf() state.saved=true;return true end
    function host:isNetworkConnected() return true end
    function host:applyShelfSnapshot() state.applied=state.applied+1 end
    view._shelf_snapshot_redraw=function() state.redraws=state.redraws+1 end
    expect(Offline.pump(host) and options,'offline sync did not start')
    return host,view,state
end
local host,view,state=fixture();local context={};host.book_metadata_context=context
expect(options.cache{books={},archive={}} and state.saved and state.applied==1,'confirmed snapshot was not saved')
drain();expect(host.shelf_view==view and state.redraws==0 and context.pending_shelf_redraw,'snapshot replaced a loading detail page')
host.book_metadata_context=nil;Popup.resumeMetadata(host,context);drain()
expect(state.redraws==1,'cancelled metadata lost the snapshot redraw')
host,view,state=fixture();context={};host.book_metadata_context=context
options.cache{books={},archive={}};drain();host.book_metadata_context=nil;host._book_detail_view={}
Popup.resumeMetadata(host,context);drain();expect(host.shelf_view==view and state.redraws==0,'snapshot redrew behind opened details')
host,view,state=fixture();context={};host.book_metadata_context=context
options.cache{books={},archive={}};drain();host.book_metadata_context=nil;state.account='two'
Popup.resumeMetadata(host,context);drain();expect(host.shelf_view==view and state.redraws==0,'old account snapshot was rendered')
host,view,state=fixture();local dialog={};Popup.show(view,dialog,function() end)
options.cache{books={},archive={}};drain();expect(host.shelf_view==view and state.redraws==0 and view._shelf_popup==dialog,'snapshot dismissed a shelf menu')
Popup.close(view);drain();expect(state.redraws==1,'closing the shelf menu lost the snapshot')
print('membership_snapshot_refresh_spec: '..checks..' checks')
