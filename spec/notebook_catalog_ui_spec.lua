package.path='./?.lua;'..package.path
local UI={close=function(_self,view) view.closed=true;if view.onCloseWidget then view:onCloseWidget() end end,
    show=function(self,view) self.top=view end,nextTick=function(_self,callback) callback() end}
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/buttondialog']=function() return {new=function(_self,data) return data end} end
package.preload['ui/widget/inputdialog']=function() return {new=function(_self,data)
    function data:getInputText() return self.input end
    return data
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local Data=require('weread.lib.notebook_catalog');local Store=require('weread.lib.notebook_catalog_store')
local Catalog=require('weread.ui.notebook_catalog')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function snapshot() return {schema=1,fetched_at=1000,books={{bookId='900001',title='Synthetic book',author='Author',noteCount=2,reviewCount=1,bookmarkCount=3},
    {bookId='unsupported',title='Unsupported',author=''}}} end
local function fixture(saved)
    local value={account='account',scope={vid='900000',epoch=1},online=false,saved=saved,notices={},writes=0,valid=true,revision=1}
    local host={_reader_session_gen=1,ui={document={}},settings={},client={}}
    host.settings.get_auth_scope=function() return value.scope end
    host.settings.auth_scope_matches=function(_self,scope) return value.valid and scope==value.scope end
    host.library_db={accountKey=function() return value.account end}
    host.closeWeReadUI=function(self) Catalog.cancel(self);self.discovery_epoch=(self.discovery_epoch or 0)+1 end
    host.cancelMyCloudMarks=function(self) self._my_marks_owner=nil;value.child_closed=true end
    for _,entry in ipairs({'showMyCloudMarks','showMyCloudThoughts','showMyCloudBookmarks'}) do
        host[entry]=function(self,id) value.opened={entry,id};self._my_marks_owner={} end
    end
    host.isNetworkOnline=function() return value.online end
    host.showInfo=function(_self,text) value.notices[#value.notices+1]=text end;host.showOffline=host.showInfo
    host.showInputDialog=function(_self,dialog) UI:show(dialog) end
    host.showList=function(_self,title,items) return {item_table=items,title=title,switchItemTable=function(self,_title,rows) self.item_table=rows end} end
    host.showBusy=function(self,_text,cancel) self.busy_message={cancel=cancel} end
    host.closeBusy=function(self) self.busy_message=nil end
    Store.new=function() return {read=function() return value.saved end,write=function(_self,row)
        if value.save_fail then return false end;value.saved=row;value.writes=value.writes+1;return true end} end
    Data.capture=function() if value.native_missing then return nil end;return {native={scope=value.scope,revision=value.revision,credentials={}},base_revision='a'} end
    Data.matches=function(_settings,access) return access.native.revision==value.revision and value.valid end
    Data.validate=function(_client,row) assert(type(row)=='table' and row.schema==1);return row end
    package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_self,task,callback)
        value.task=task;value.complete=callback;value.started=(value.started or 0)+1;return true end,
        cancel=function() value.cancelled=(value.cancelled or 0)+1 end} end}
    return host,value
end
local function row(menu,label) for _,item in ipairs(menu.item_table) do if item.text==label then return item end end;error('missing '..label) end
local function listed(menu)
    local names={};for _,item in ipairs(menu.item_table) do if item.notebook_id then names[#names+1]=item.text end end
    return table.concat(names,',')
end
local host,value=fixture(snapshot());expect(Catalog.show(host),'cached catalog did not open')
local menu=host._notebook_menu
expect(not value.started and row(menu,'Synthetic book').mandatory=='Author','cached catalog not shown offline')
expect(row(menu,'Save all notebook notes for offline use'),'offline notebook-save entry missing')
row(menu,'Save all notebook notes for offline use').callback()
expect(not value.started and #value.notices==1 and not menu._shelf_popup,'offline save attempted a request')
row(menu,'Save only missing notebook notes').callback()
expect(not value.started and #value.notices==2 and not menu._shelf_popup,'offline missing-only save attempted a request')
row(menu,'Synthetic book').callback();local popup=menu._shelf_popup
expect(popup.buttons[1][1].text=='My cloud highlights (2)' and popup.buttons[2][1].text=='My cloud thoughts (1)' and popup.buttons[3][1].text=='My cloud bookmarks (3)','counts or actions missing')
popup.buttons[2][1].callback();expect(value.opened[1]=='showMyCloudThoughts' and value.opened[2]=='900001','thought action wrong')
Catalog.cancel(host);expect(value.child_closed and not host._notebook_menu,'owned child not closed')
host,value=fixture();value.online=true
expect(Catalog.show(host,{search=true}),'direct saved note search did not open')
expect(host._notebook_menu._shelf_popup and host._notebook_menu._shelf_popup.title=='Search all saved notes'
    and not value.started,'direct search was displaced by an automatic refresh')
Catalog.cancel(host)
host,value=fixture(snapshot());Catalog.show(host);menu=host._notebook_menu
row(menu,'Unsupported').callback();expect(#value.notices==1 and not menu._shelf_popup,'unsupported book opened')
value.online=true;row(menu,'Refresh my notebooks').callback();local old=menu.item_table
row(menu,'Synthetic book').callback();local changed=snapshot();changed.books[1].title='Updated';value.complete(changed)
expect(value.writes==1 and menu.item_table==old and menu._shelf_popup,'refresh disturbed popup')
UI:close(menu._shelf_popup);expect(row(menu,'Updated'),'deferred refresh missing')
local stale=row(menu,'Updated').callback;Catalog.cancel(host);stale();expect(not menu._shelf_popup,'stale row opened')
local search_snapshot={schema=1,fetched_at=1000,books={
    {bookId='900001',title='Alpha book',author='Other',noteCount=1,reviewCount=0,bookmarkCount=0},
    {bookId='900002',title='Beta book',author='ALPHA author',noteCount=0,reviewCount=3,bookmarkCount=0},
    {bookId='900003',title='Gamma book',author='Writer',noteCount=1,reviewCount=2,bookmarkCount=0},
    {bookId='900004',title='Unknown count',author='Writer'},
}}
host,value=fixture(search_snapshot);Catalog.show(host);menu=host._notebook_menu
local hidden_callback=row(menu,'Gamma book').callback
local function search(text)
    row(menu,'Search notebooks').callback();local dialog=menu._shelf_popup
    dialog.input=text;dialog.buttons[1][2].callback()
end
search('  alpha  ')
expect(row(menu,'Alpha book') and row(menu,'Beta book') and not pcall(row,menu,'Gamma book'),'search missed title/author or retained unrelated book')
hidden_callback();expect(not menu._shelf_popup,'stale row escaped search filter')
expect(not value.started and value.writes==0,'offline search accessed network or saved query')
row(menu,'Sort notebooks').callback();popup=menu._shelf_popup;popup.buttons[2][1].callback()
expect(listed(menu)=='Beta book,Alpha book','sort did not compose with search')
search('writer');expect(listed(menu)=='Gamma book,Unknown count','unknown count sorted ahead of known count')
search('missing');expect(row(menu,'No matching notebooks.').select_enabled==false,'empty search did not show message')
row(menu,'Search notebooks').callback();popup=menu._shelf_popup;popup.buttons[1][1].callback()
expect(listed(menu)=='Beta book,Gamma book,Alpha book,Unknown count','count sort or stable ties changed')
expect(host._notebook_owner.value.books[1].title=='Alpha book' and host._notebook_owner.value.books[2].title=='Beta book',
    'sorting mutated the saved list')
row(menu,'Sort notebooks').callback();popup=menu._shelf_popup;popup.buttons[1][1].callback()
expect(listed(menu)=='Alpha book,Beta book,Gamma book,Unknown count','original order not restored')
search('a long search query longer than display')
expect(row(menu,'Search notebooks').mandatory=='a long search qu…','long search occupied entire row')
row(menu,'Search notebooks').callback();popup=menu._shelf_popup;popup.input=string.rep('x',1025);popup.buttons[1][2].callback()
expect(menu._shelf_popup==popup and #value.notices==1,'too-long query closed input')
Catalog.cancel(host);popup.input='Alpha';popup.buttons[1][2].callback();expect(not host._notebook_menu,'stale search reopened closed menu')
host,value=fixture(search_snapshot);value.online=true;Catalog.show(host);menu=host._notebook_menu
row(menu,'Refresh my notebooks').callback();row(menu,'Search notebooks').callback();popup=menu._shelf_popup
local refreshed={schema=1,fetched_at=1001,books={{bookId='900005',title='New alpha',author='Writer',noteCount=3,reviewCount=0,bookmarkCount=0}}}
value.complete(refreshed);expect(menu._shelf_popup==popup and row(menu,'Alpha book'),'refresh displaced search input')
popup.input='alpha';popup.buttons[1][2].callback()
expect(row(menu,'New alpha') and not pcall(row,menu,'Alpha book') and value.writes==1,'search did not apply to refreshed snapshot')
Catalog.cancel(host)
for _,change in ipairs({'account','epoch','session','document','scope','revision','close','cancel'}) do
    host,value=fixture(snapshot());value.online=true;Catalog.show(host);menu=host._notebook_menu
    row(menu,'Refresh my notebooks').callback();local callback=value.complete
    if change=='account' then value.account='other' elseif change=='epoch' then host.discovery_epoch=host.discovery_epoch+1
    elseif change=='session' then host._reader_session_gen=2 elseif change=='document' then host.ui.document={}
    elseif change=='scope' then value.valid=false elseif change=='revision' then value.revision=2
    elseif change=='close' then menu:onCloseWidget() else host.busy_message.cancel() end
    callback(snapshot());expect(value.writes==0 and #value.notices==0 and not host.busy_message,change..' applied stale result')
end
host,value=fixture(snapshot());value.online=true;value.save_fail=true;Catalog.show(host);menu=host._notebook_menu
row(menu,'Refresh my notebooks').callback();changed=snapshot();changed.books[1].title='Unsaved';value.complete(changed)
expect(value.writes==0 and row(menu,'Synthetic book') and #value.notices==1,'save failure replaced cache')
host,value=fixture();value.online=true;Catalog.show(host);expect(value.started==1,'initial online fetch not started')
value.complete({error='failed'});expect(value.writes==0 and #value.notices==1,'failed response saved')
host,value=fixture(snapshot());value.online=true;Catalog.show(host);menu=host._notebook_menu
local renewals=0
host.native_renewal={start=function(_self,options,complete)
    renewals=renewals+1;expect(options.expected_revision==1,'renewed unrelated grant')
    value.revision=value.revision+2;complete(true);return true,{}
end}
row(menu,'Refresh my notebooks').callback();value.complete({native_expired=true})
expect(renewals==1 and value.started==2 and host._notebook_owner.context,'expiry did not recover once')
value.complete({native_expired=true})
expect(renewals==1 and value.writes==0 and not host._notebook_owner.context and #value.notices==1,'repeated expiry renewed again')
local original_editor=package.loaded['weread.ui.thought_editor'];local draft_owner
package.loaded['weread.ui.thought_editor']={cancel=function() end,drafts=function(selected,owner,is_current)
    if is_current(selected,owner) then draft_owner=owner end end}
host,value=fixture();Catalog.show(host);menu=host._notebook_menu
local draft_action=row(menu,'Local thought drafts').callback;draft_action()
expect(draft_owner==host._notebook_owner and not value.started,'notebook did not open local drafts offline')
draft_owner=nil;Catalog.cancel(host);draft_action();expect(not draft_owner,'closed notebook retained draft action')
package.loaded['weread.ui.thought_editor']=original_editor
print('PASS: notebook native UI lifecycle ('..checks..' checks)')
