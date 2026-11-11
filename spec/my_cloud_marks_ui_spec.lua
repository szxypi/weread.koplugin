package.path='./?.lua;'..package.path
local UI={close=function(_self,view) view.closed=true;if view.onCloseWidget then view:onCloseWidget() end end,
    show=function(self,view) self.top=view end,nextTick=function(_self,callback) callback() end}
-- Capture popup ownership through the actual helper.
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['ui/widget/textviewer']=function() return {new=function(_self,v) return v end} end
local Data=require('weread.lib.my_cloud_marks');local Store=require('weread.lib.my_cloud_marks_store')
local Marks=require('weread.ui.my_cloud_marks')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function snapshot()
    return {schema=1,book_id='900001',fetched_at=1000,updated={{bookmarkId='synthetic-1',type=1,chapterUid=7,markText='合成引用',range='12-24'},
        {bookmarkId='synthetic-2',type=0,chapterUid=7}},chapters={{chapterUid=7,title='合成章节'}}}
end
local function fixture(saved)
    local value={account='synthetic-account',scope={vid='900000',epoch=1},online=false,saved=saved,notices={},writes=0,valid=true,revision=1}
    local host={_reader_session_gen=1,ui={document={}},_book_detail_view={},settings={},client={}}
    host.settings.get_auth_scope=function() return value.scope end
    host.settings.auth_scope_matches=function(_self,scope) return value.valid and scope==value.scope end
    host.library_db={accountKey=function() return value.account end}
    host.isNetworkOnline=function() return value.online end
    host.showInfo=function(_self,text) value.notices[#value.notices+1]=text end
    host.showOffline=host.showInfo
    host.showList=function(_self,title,items)
        return {item_table=items,title=title,switchItemTable=function(self,_title,rows) self.item_table=rows end}
    end
    host.showBusy=function(self,_text,cancel) self.busy_message={cancel=cancel} end
    host.closeBusy=function(self) self.busy_message=nil end
    Store.new=function() return {read=function() return value.saved end,write=function(_self,row)
        if value.save_fail then return false end;value.saved=row;value.writes=value.writes+1;return true
    end} end
    Data.capture=function() if value.native_missing then return nil end;return {native={scope=value.scope,revision=value.revision,credentials={}},base_revision='a'} end
    Data.matches=function(_settings,access) return access.native.revision==value.revision and value.valid end
    Data.validate=function(_client,row,id) assert(type(row)=='table' and row.schema==1 and row.book_id==id);return row end
    package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_self,task,callback)
        value.task=task;value.complete=callback;value.started=(value.started or 0)+1;return true
    end,cancel=function() value.cancelled=(value.cancelled or 0)+1 end} end}
    return host,value
end
local function row(menu,label)
    for _,item in ipairs(menu.item_table) do if item.text==label then return item end end
    error('missing row '..label)
end
local host,value=fixture(snapshot())
expect(Marks.show(host,'900001'),'saved marks did not open offline')
local menu=host._my_marks_menu
expect(not value.started and row(menu,'合成引用') and row(menu,'合成章节'),'offline cached quote/bookmark missing')
row(menu,'Highlights only').callback();expect(not pcall(row,menu,'合成章节'),'bookmark escaped highlights filter')
row(menu,'Bookmarks only').callback();expect(not pcall(row,menu,'合成引用'),'highlight escaped bookmark filter')
row(menu,'All cloud marks').callback();row(menu,'合成引用').callback()
expect(menu._shelf_popup.text=='合成章节\n\n合成引用','native popup lost full quote')
expect(menu._shelf_popup.buttons_table[1][1].id=='open_highlight','valid saved range lost original-text action')
value.online=true;row(menu,'Refresh my cloud marks').callback()
expect(value.started==1 and host.busy_message,'refresh did not start owned worker')
local before=menu.item_table;local changed=snapshot();changed.updated[1].markText='新引用'
value.complete(changed)
expect(value.writes==1 and not host.busy_message and menu.item_table==before and menu._shelf_popup,'refresh replaced a live popup')
UI:close(menu._shelf_popup)
expect(menu.item_table~=before and row(menu,'新引用'),'deferred redraw did not run after popup closed')
local stale=row(menu,'新引用').callback;Marks.cancel(host);stale()
expect(not host._my_marks_menu and not menu._shelf_popup,'stale popup reopened after closing')
for _,change in ipairs({'account','epoch','session','document','parent','scope','revision','close','cancel'}) do
    host,value=fixture(snapshot());value.online=true;Marks.show(host,'900001');menu=host._my_marks_menu
    row(menu,'Refresh my cloud marks').callback();local callback=value.complete
    if change=='account' then value.account='other' elseif change=='epoch' then host.discovery_epoch=1
    elseif change=='session' then host._reader_session_gen=2 elseif change=='document' then host.ui.document={}
    elseif change=='parent' then host._book_detail_view={} elseif change=='scope' then value.valid=false
    elseif change=='revision' then value.revision=2 elseif change=='close' then menu:onCloseWidget()
    else host.busy_message.cancel() end
    callback(snapshot());expect(value.writes==0 and #value.notices==0 and not host.busy_message,change..' applied stale worker result')
end
host,value=fixture(snapshot());value.online=true;value.save_fail=true;Marks.show(host,'900001');menu=host._my_marks_menu
row(menu,'Refresh my cloud marks').callback();changed=snapshot();changed.updated[1].markText='New unsaved';value.complete(changed)
expect(value.writes==0 and row(menu,'合成引用') and #value.notices==1,'failed save replaced cache')
host,value=fixture();value.online=true;Marks.show(host,'900001');expect(value.started==1,'empty first visit did not load')
value.complete({error='worker_failed'});expect(value.writes==0 and #value.notices==1,'failed response saved as empty success')
Marks.cancel(host)
expect(not Marks.show(host,'CB_Synthetic') and not Marks.show(host,'MP_WXS_synthetic'),'unverified book type opened')
-- Explicit expiry permits one parent-owned renewal and one replayed GET only.
host,value=fixture(snapshot());value.online=true;Marks.show(host,'900001');menu=host._my_marks_menu
local renewals=0
host.native_renewal={start=function(_self,options,complete)
    renewals=renewals+1;expect(options.expected_revision==1,'renewed unrelated grant');value.revision=value.revision+2;complete(true);return true,{}
end}
row(menu,'Refresh my cloud marks').callback();value.complete({native_expired=true})
expect(renewals==1 and value.started==2 and host._my_marks_owner.context,'expiry did not recover/retry once')
value.complete({native_expired=true})
expect(renewals==1 and value.writes==0 and not host._my_marks_owner.context and #value.notices==1,'second expiry renewed repeatedly')
-- A queued cancel from a completed busy dialog cannot stop a newer refresh.
host,value=fixture(snapshot());value.online=true;Marks.show(host,'900001');menu=host._my_marks_menu
row(menu,'Refresh my cloud marks').callback();local old_cancel=host.busy_message.cancel
value.complete(snapshot());row(menu,'Refresh my cloud marks').callback();old_cancel()
expect(host._my_marks_owner.context and host.busy_message,'old cancel closed new refresh')
Marks.cancel(host)
host,value=fixture(snapshot());value.online=true;value.native_missing=true;Marks.show(host,'900001');menu=host._my_marks_menu
row(menu,'Refresh my cloud marks').callback();expect(not value.started and #value.notices==1,'missing grant started worker')
-- The thought adapter shares ownership while keeping its rows and filters separate.
host,value=fixture();value.saved={schema=1,book_id='900001',fetched_at=1000,reviews={
    {reviewId='synthetic-thought-a',content='My quoted thought',abstract='Quoted source',isPrivate=1,chapterName='Chapter'},
    {reviewId='synthetic-thought-b',content='My standalone thought',abstract='',chapterName='Chapter'},
    {reviewId='synthetic-thought-c',content='',abstract='Only source'}}}
package.loaded['weread.lib.my_cloud_thoughts']={capture=Data.capture,matches=Data.matches,validate=Data.validate,EXPIRED='my_thoughts/native_expired'}
expect(Marks.show(host,'900001','thoughts'),'thought adapter did not open')
menu=host._my_marks_menu;expect(menu.title=='My cloud thoughts','thought mode retained the highlight title')
row(menu,'Thoughts with quoted text').callback()
expect(row(menu,'My quoted thought') and not pcall(row,menu,'My standalone thought'),'thought quote filter used the review type')
row(menu,'My quoted thought').callback()
expect(menu._shelf_popup.title=='Private thought' and menu._shelf_popup.text=='Chapter\n\nQuoted text\nQuoted source\n\nThought\nMy quoted thought','thought popup omitted quote or private state')
UI:close(menu._shelf_popup);row(menu,'Only source').callback()
expect(menu._shelf_popup.text:find('No thought text was returned.',1,true),'quoted-only thought hid its missing body')
UI:close(menu._shelf_popup);row(menu,'Other thoughts').callback()
expect(row(menu,'My standalone thought') and not pcall(row,menu,'My quoted thought'),'standalone thought filter failed')
local old_refresh=row(menu,'Refresh my cloud thoughts').callback
value.online=true;old_refresh();local old_complete=value.complete
value.saved=snapshot();Marks.show(host,'900001');local replacement=host._my_marks_menu
old_refresh();old_complete({schema=1,book_id='900001',fetched_at=1001,reviews={}})
expect(host._my_marks_menu==replacement and value.writes==0 and not host.busy_message and value.cancelled==1,'old thought result changed a highlight view')
Marks.cancel(host)
expect(not Marks.show(host,'900001','untrusted_table'),'arbitrary personal note mode accepted')
print('PASS: own marks native UI ownership, filters, cache and cancellation ('..checks..' checks)')
