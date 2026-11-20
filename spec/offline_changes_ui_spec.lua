package.path='./?.lua;'..package.path
local UI={}
function UI:close(view) if view.onCloseWidget then view:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.ui.shelf_popup']=function() return {
    current=function(owner,view) return owner._shelf_popup==view end,
    close=function(owner) local view=owner._shelf_popup;owner._shelf_popup=nil;if view then UI:close(view) end end,
    show=function(owner,view) owner._shelf_popup=view end,
} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,
    T=function(text,...) for i=1,select('#',...) do text=text:gsub('%%'..i,tostring(select(i,...))) end;return text end} end
local state
local function module(kind)
    return {list=function() if state.error==kind then return nil,'storage' end;return state[kind] end,
        get=function(_host,id) if state.get_error==kind then return nil,'storage' end
            for _,v in ipairs(state[kind]) do if v.book_id==id then return v end end end}
end
package.loaded['weread.ui.finish_offline']=module('finished')
package.loaded['weread.ui.membership_offline']=module('members')
package.loaded['weread.ui.shelf_state']={show=function(_host,id) state.selected=id end}
local Changes=require('weread.ui.offline_changes')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function entry(id,kind,phase,time,title)
    return {book_id=id,id=kind..id,phase=phase,created_at=time,before=false,desired=true,title=title}
end
local function fixture()
    state={account='first',finished={entry('41','f','queued',2)},members={entry('42','m','queued',1,'Saved title')}}
    local host={client={},library_db={},ui={document={}},shelf_regular={{bookId='41',title='Shelf title'}},settings={}}
    function host.library_db:accountKey() return state.account end
    function host.library_db:open() end
    function host.settings:get() return {} end
    function host:showInfo(message) state.info=message end
    function host:showList(title,items) state.items=items;return {title=title,item_table=items} end
    function host:isNetworkConnected() error('local list must not use network') end
    return host
end
local host=fixture();host.shelf_view={}
expect(Changes.show(host),'list did not open')
expect(#state.items==2 and state.items[1].text=='Saved title' and state.items[2].text=='Shelf title','sort or identity failed')
expect(state.items[1].mandatory=='Add to shelf · Pending sync' and state.items[2].mandatory=='Mark finished · Pending sync','action labels lost')
expect(host.shelf_view._shelf_popup==host._offline_changes_menu,'shelf did not own list')
state.items[1].callback();expect(state.selected=='42' and not host._offline_changes_menu,'selection did not open current shelf status')
host=fixture();state.members[1].title='';expect(Changes.show(host),'missing-title list failed')
expect(state.items[1].text=='Book ID: 42','missing title was guessed')
host=fixture();host.shelf_regular=nil
function host.library_db:getShelf() return {{bookId='41',title='Cached shelf title'}} end
expect(Changes.show(host) and state.items[2].text=='Cached shelf title','cached shelf title was not loaded in the main menu')
host=fixture();Changes.show(host);local stale=state.items[1].callback;state.account='second';stale()
expect(not state.selected,'old-account selection survived account change')
host=fixture();Changes.show(host);stale=state.items[1].callback;state.members[1]=entry('42','replacement','queued',1,'New title');stale()
expect(not state.selected and state.info:find('list was refreshed',1,true) and state.items[1].text=='New title','replaced record was selected')
host=fixture();Changes.show(host);stale=state.items[1].callback;state.members={};stale()
expect(not state.selected and state.items[1].text=='Shelf title','completed record was selected')
host=fixture();state.finished={};state.members={};expect(not Changes.show(host) and state.info=='No offline changes.','empty list misreported')
host=fixture();state.error='finished';expect(not Changes.show(host) and state.info=='Could not read offline changes.','unreadable queue hidden')
host=fixture();Changes.show(host);state.get_error='members';state.items[1].callback()
expect(state.info=='Could not read offline changes.' and host._offline_changes_menu and not state.selected,'read error acted on stale item')
host=fixture();state.members[1].phase='dispatching';Changes.show(host)
expect(state.items[1].mandatory=='Add to shelf · Needs review','uncertain write was shown as queued')
host=fixture();Changes.show(host);stale=state.items[1].callback;Changes.cancel(host);stale()
expect(not state.selected,'closed list retained callback')
print('offline_changes_ui_spec: '..checks..' checks')
