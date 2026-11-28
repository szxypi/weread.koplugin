package.path='./?.lua;'..package.path
local ticks={};local UI={}
function UI:nextTick(callback) ticks[#ticks+1]=callback end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/focusmanager']=function() return {FOCUS_ONLY_ON_NT=2} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,T=function(value) return value end} end
local Finish=require('weread.ui.finish_offline');local Popup=require('weread.ui.shelf_popup')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function drain() while #ticks>0 do local pending=ticks;ticks={};for _,fn in ipairs(pending) do fn() end end end
local function fixture()
    local state={account='one',flags={['41']=true,['42']=false},redraws=0}
    local book={bookId='41',finishReading=0,progress=.25};local other={bookId='42',finishReading=1}
    local view={books={book,other},selected={x=2,y=3}}
    local host={shelf_view=view,shelf_regular=view.books,shelf_groups={},settings={get=function() return {} end},library_db={}}
    function host.library_db:accountKey() return state.account end
    function host.library_db:getShelfStatus(id)
        if state.fail then return nil end
        return {present=true,book={finishReading=state.flags[id] and 1 or 0}}
    end
    view._finish_redraw=function() state.redraws=state.redraws+1 end
    return host,view,state,book,other
end
local host,view,state,book=fixture();Finish.refresh_view(host,'41')
expect(state.redraws==1 and book.finishReading==1 and book.progress==.25 and not view._finish_dirty,'confirmed status not refreshed safely')
host,view,state,book=fixture();local popup={};Popup.show(view,popup,function() end);Finish.refresh_view(host,'41')
expect(state.redraws==0 and book.finishReading==0 and view._shelf_popup==popup,'background update displaced popup')
Popup.close(view);drain();expect(state.redraws==1 and book.finishReading==1,'popup close lost pending refresh')
host,view,state,book=fixture();popup={};Popup.show(view,popup,function() end);Finish.refresh_view(host,'41')
host.shelf_view={};Popup.close(view);drain()
expect(state.redraws==0 and book.finishReading==0,'old page was updated after navigation')
host,view,state,book=fixture();popup={};Popup.show(view,popup,function() end);Finish.refresh_view(host,'41')
state.account='two';Popup.close(view);drain();expect(state.redraws==0 and book.finishReading==0,'old account updated a page')
host,view,state,book=fixture();host._book_detail_view={};Finish.refresh_view(host,'41')
expect(state.redraws==0 and book.finishReading==0 and view._finish_dirty['41'],'detail screen was interrupted')
host._book_detail_view=nil;expect(Finish.reconcile_view(host,view) and book.finishReading==1,'detail return lost update')
host,view,state,book=fixture();host.book_metadata_context={};local metadata=host.book_metadata_context
Finish.refresh_view(host,'41')
expect(state.redraws==0 and book.finishReading==0 and view._finish_dirty['41']
    and metadata.pending_shelf_redraw,'finished mark interrupted book metadata loading')
host.book_metadata_context=nil;Popup.resumeMetadata(host,metadata);drain()
expect(state.redraws==1 and book.finishReading==1 and not view._finish_dirty,'metadata cancellation lost finished mark refresh')
host,view,state,book=fixture();host.book_metadata_context={};metadata=host.book_metadata_context
Finish.refresh_view(host,'41');host.book_metadata_context=nil;host._book_detail_view={};Popup.resumeMetadata(host,metadata);drain()
expect(state.redraws==0 and view._finish_dirty['41'],'metadata completion redrew behind details')
host._book_detail_view=nil;expect(Finish.reconcile_view(host,view) and book.finishReading==1,'detail return lost pending finished mark')
host,view,state,book=fixture();host._shelf_state_menu={};Finish.refresh_view(host,'41')
expect(state.redraws==0 and book.finishReading==0 and view._finish_dirty['41'],'shelf status menu was interrupted')
host._shelf_state_menu=nil;Finish.flush_view(host)
expect(state.redraws==1 and book.finishReading==1,'shelf status close lost pending refresh')
host,view,state,book=fixture();state.fail=true;Finish.refresh_view(host,'41')
expect(state.redraws==0 and view._finish_dirty['41'] and book.finishReading==0,'unreadable saved status replaced the view')
state.fail=false;Finish.refresh_view(host,'41');expect(state.redraws==1 and book.finishReading==1,'saved status retry failed')
local other;host,view,state,book,other=fixture();popup={};Popup.show(view,popup,function() end)
Finish.refresh_view(host,'41');Finish.refresh_view(host,'42');Popup.close(view);drain()
expect(state.redraws==1 and book.finishReading==1 and other.finishReading==0,'deferred updates were not combined')
host,view,state,book,other=fixture()
local conflicting={bookId='42',book_id='43',finishReading=1}
view.books={book};view._finish_shelf_source={book,other,conflicting}
Finish.refresh_view(host,'42')
expect(state.redraws==1 and view._finish_status_changed and other.finishReading==0 and conflicting.finishReading==1,
    'a confirmed mark did not update the hidden book with a matching identity')
local fresh={layout={{},{},{nil,{}}},moveFocusTo=function(self,x,y,flags) self.focus={x,y,flags} end}
Finish.redraw_preserving_focus(host,view,function() host.shelf_view=fresh end)
expect(fresh.focus[1]==2 and fresh.focus[2]==3 and fresh.focus[3]==2,'focus did not survive redraw')
print('finish_offline_refresh_spec: '..checks..' checks')
