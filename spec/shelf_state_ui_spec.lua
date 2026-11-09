package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function() return {close=function(_self,menu) menu.closed=true end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
local State=require('weread.ui.shelf_state')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    local value={account='a',notices={},menus={}}
    local host={_reader_session_gen=1,ui={document={}},_book_detail_view={},
        library_db={accountKey=function() return value.account end,getShelfStatus=function(_self,id)
            expect(id=='42','wrong book snapshot requested')
            return value.entry
        end},
        showList=function(_self,_title,items) local menu={item_table=items};value.menus[#value.menus+1]=menu;return menu end,
        showInfo=function(_self,text) value.notices[#value.notices+1]=text end,
        refreshBookshelf=function(_self,_view,options) value.callback=options.on_loaded end,
        closeWeReadUI=function(self) State.cancel(self);self._book_detail_view=nil;self.discovery_epoch=(self.discovery_epoch or 0)+1 end}
    return host,value
end
local function row(menu,label)
    for _,item in ipairs(menu.item_table) do if item.text==label then return item end end
    error('missing row: '..label)
end
local host,value=fixture()
value.entry={present=true,book={isTop=true,secret=false,finishReading=0,finished=1,progress=100},cached_at=1000}
State.show(host,'42');local menu=host._shelf_state_menu
expect(row(menu,'Pinned').mandatory=='Yes' and row(menu,'Private reading').mandatory=='No' and row(menu,'Finished reading').mandatory=='No','snapshot statuses used wrong field')
row(menu,'Refresh shelf status').callback()
expect(not host._shelf_state_menu and value.callback~=nil,'refresh did not close owned views and use shelf workflow')
value.callback(true);expect(host._shelf_state_menu~=nil,'successful refresh did not reopen same snapshot')
host._shelf_state_menu:onCloseWidget();value.callback(true)
expect(not host._shelf_state_menu,'duplicate refresh callback reopened dismissed snapshot')
for _,change in ipairs({'account','epoch','session','document','parent'}) do
    host,value=fixture();State.show(host,'42');menu=host._shelf_state_menu;row(menu,'Refresh shelf status').callback()
    if change=='account' then value.account='b'
    elseif change=='epoch' then host.discovery_epoch=99
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='document' then host.ui.document={}
    else host._book_detail_view={} end
    value.callback(true)
    expect(not host._shelf_state_menu and #value.notices==0,change..' reopened stale state')
end
host,value=fixture();State.show(host,'42');menu=host._shelf_state_menu
expect(row(menu,'Pinned').mandatory=='Not provided' and row(menu,'Finished reading').mandatory=='Not provided','absence declared false')
State.show(host,'42');row(menu,'Refresh shelf status').callback()
expect(value.callback==nil and host._shelf_state_menu~=menu,'old menu refreshed replacement')
menu=host._shelf_state_menu;value.account='b';row(menu,'About shelf status').callback()
expect(#value.notices==0,'old account menu showed status help')
host,value=fixture();State.show(host,'42');host.shelf_refreshing=true;row(host._shelf_state_menu,'Refresh shelf status').callback()
expect(not value.callback and #value.notices==1,'duplicate shelf refresh started')
host,value=fixture();State.show(host,'42');row(host._shelf_state_menu,'Refresh shelf status').callback();value.callback(false)
expect(not host._shelf_state_menu and #value.notices==1,'failed snapshot save displayed old flags as newly refreshed')
State.cancel(host)
host,value=fixture();State.show(host,'42');menu=host._shelf_state_menu;menu:onCloseWidget();row(menu,'Refresh shelf status').callback()
expect(not host._shelf_state_menu and not value.callback,'dismissed native menu retained active callbacks')
host,value=fixture();host.library_db.getShelfStatus=function() value.account='b';return {book={secret=1}} end
expect(not State.show(host,'42') and #value.menus==0,'account changed during cache read exposed old state')
host,value=fixture();value.entry={present=false,cached_at=1000};State.show(host,'42');menu=host._shelf_state_menu
expect(row(menu,'In cloud bookshelf').mandatory=='No' and row(menu,'The last saved bookshelf does not contain this book.'),'saved absence remained unknown')
expect(row(menu,'Finished reading').mandatory=='Not provided','absence inferred a finished flag')
host,value=fixture();State.show(host,'42')
expect(row(host._shelf_state_menu,'In cloud bookshelf').mandatory=='Unknown','no snapshot declared not-on-shelf')
host,value=fixture();host.library_db.getShelfStatus=function() error('synthetic read failure') end;State.show(host,'42')
expect(row(host._shelf_state_menu,'In cloud bookshelf').mandatory=='Unknown','database failure declared not-on-shelf')
host,value=fixture();value.entry={present=true,cached_at=0};State.show(host,'42');menu=host._shelf_state_menu
expect(row(menu,'In cloud bookshelf').mandatory=='Yes','positive membership lost')
expect(row(menu,'Saved shelf snapshot').mandatory=='Time unavailable' and row(menu,'Saved status fields are unavailable for this book.'),'unreadable fields or clock became false absence')
print('PASS: shelf status native menu coordination ('..checks..' checks)')
