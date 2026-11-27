package.path='./?.lua;'..package.path
local UI={close=function(_self,view) view.closed=true;if view.onCloseWidget then view:onCloseWidget() end end,
    show=function(self,view) self.top=view end,nextTick=function(_self,callback) callback() end}
-- Capture popup ownership through the actual helper.
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.ui.thought_text']=function() return {viewer=function(v) return v end} end
package.preload['ui/widget/inputdialog']=function() return {new=function(_self,data)
    function data:getInputText() return self.input end
    return data
end} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_self,data) return data end} end
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
    host.isNetworkOnline=function() error('notes list probed Internet on the UI thread') end
    host.isNetworkLinkAvailable=function()
        value.link_checks=(value.link_checks or 0)+1;return value.online
    end
    host.showInfo=function(_self,text) value.notices[#value.notices+1]=text end
    host.showOffline=host.showInfo
    host.showInputDialog=function(_self,dialog) UI:show(dialog) end
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
expect(not value.link_checks and not value.started and row(menu,'合成引用') and row(menu,'合成章节'),'offline cached quote/bookmark missing')
row(menu,'Highlights only').callback();expect(not pcall(row,menu,'合成章节'),'bookmark escaped highlights filter')
row(menu,'Bookmarks only').callback();expect(not pcall(row,menu,'合成引用'),'highlight escaped bookmark filter')
row(menu,'All cloud marks').callback();row(menu,'合成引用').callback()
expect(menu._shelf_popup.text=='合成章节\n\n合成引用','native popup lost full quote')
expect(menu._shelf_popup.buttons_table[1][1].id=='open_highlight','valid saved range lost original-text action')
value.online=true;row(menu,'Refresh my cloud marks').callback()
expect(value.link_checks==1 and value.started==1 and host.busy_message,'refresh did not start owned worker after one link check')
local before=menu.item_table;local changed=snapshot();changed.updated[1].markText='新引用'
value.complete(changed)
expect(value.writes==1 and not host.busy_message and menu.item_table==before and menu._shelf_popup,'refresh replaced a live popup')
UI:close(menu._shelf_popup)
expect(menu.item_table~=before and row(menu,'新引用'),'deferred redraw did not run after popup closed')
local stale=row(menu,'新引用').callback;Marks.cancel(host);stale()
expect(not host._my_marks_menu and not menu._shelf_popup,'stale popup reopened after closing')

-- Saved-note search remains local, composes with filters and owns its dialog.
local search_snapshot=snapshot();search_snapshot.updated[1].markText='Alpha quotation'
search_snapshot.updated[1].abstract='Other excerpt';search_snapshot.chapters[1].title='Synthetic chapter'
host,value=fixture(search_snapshot);Marks.show(host,'900001');menu=host._my_marks_menu
local function search(text)
    row(menu,'Search saved notes').callback();local dialog=menu._shelf_popup
    dialog.input=text;dialog.buttons[1][2].callback()
end
search('  ALPHA　');expect(row(menu,'Alpha quotation') and not pcall(row,menu,'Synthetic chapter'),
    'search did not trim/fold or limit results')
expect(not value.started and value.writes==0,'offline search accessed the server or saved the query')
row(menu,'Bookmarks only').callback();expect(row(menu,'No matching notes in this view.'),'search did not compose with type filter')
row(menu,'All cloud marks').callback();search('other excerpt')
expect(row(menu,'Alpha quotation'),'search missed the original quote when the display text differs')
search('synthetic chapter');expect(row(menu,'Alpha quotation') and row(menu,'Synthetic chapter'),'search missed chapter names')
search('a long search query longer than its display');expect(row(menu,'Search saved notes').mandatory=='a long search qu…',
    'long search text occupied the entire menu row')
row(menu,'Search saved notes').callback();local active=menu._shelf_popup
active.input=string.rep('a',1025);active.buttons[1][2].callback()
expect(menu._shelf_popup==active and #value.notices==1,'long search closed dialog or silently changed results')
active.buttons[1][1].callback();expect(row(menu,'Alpha quotation') and row(menu,'Synthetic chapter'),'clear did not restore saved notes')
row(menu,'Search saved notes').callback();local stale_search=menu._shelf_popup
Marks.cancel(host);stale_search.input='alpha';stale_search.buttons[1][2].callback()
expect(not host._my_marks_menu and not menu._shelf_popup,'stale search reopened a closed owner')

-- Ordering is local to this window, stable for ties and composes with search
-- and the mark-type filter without changing the saved snapshot.
local ordered=snapshot();ordered.updated={
    {bookmarkId='a',type=1,markText='Match A',createTime=200,chapterIdx=2},
    {bookmarkId='b',type=0,markText='Match B',createTime=100,chapterIdx=3},
    {bookmarkId='c',type=1,markText='Match C',createTime=0},
    {bookmarkId='d',type=1,markText='Match D',createTime=200,chapterIdx=1},
    {bookmarkId='e',type=1,markText='Match E',chapterIdx=1},
}
host,value=fixture(ordered);Marks.show(host,'900001');menu=host._my_marks_menu
local function visible_ids()
    local ids={};for _,item in ipairs(menu.item_table) do if item.my_note_id then ids[#ids+1]=item.my_note_id end end
    return table.concat(ids,',')
end
local function sort(index)
    row(menu,'Sort saved notes').callback();local dialog=menu._shelf_popup
    dialog.buttons[index][1].callback()
end
local stale_note=row(menu,'Match A').callback
sort(2);expect(visible_ids()=='a,d,b,c,e','newest order or stable ties were wrong')
stale_note();expect(not menu._shelf_popup,'old note action survived a new ordering')
sort(3);expect(visible_ids()=='b,a,d,c,e','oldest order or missing dates were wrong')
sort(4);expect(visible_ids()=='d,e,a,b,c','chapter order or missing chapter was wrong')
row(menu,'Highlights only').callback();expect(visible_ids()=='d,e,a,c','sort ignored the selected type')
row(menu,'Search saved notes').callback();local sorted_search=menu._shelf_popup
sorted_search.input='match a';sorted_search.buttons[1][2].callback()
expect(visible_ids()=='a' and row(menu,'Sort saved notes').mandatory=='Chapter order','search reset the ordering')
expect(ordered.updated[1].bookmarkId=='a' and ordered.updated[2].bookmarkId=='b' and value.writes==0 and not value.started,
    'sorting changed saved order or accessed network')
row(menu,'Sort saved notes').callback();local stale_sort=menu._shelf_popup
Marks.cancel(host);stale_sort.buttons[1][1].callback()
expect(not host._my_marks_menu and not menu._shelf_popup,'old sort dialog reopened a closed owner')
ordered.updated[#ordered.updated+1]={bookmarkId='f',type=0,markText='Match F',createTime=300,chapterIdx=2}
host,value=fixture(ordered);Marks.show(host,'900001','bookmarks');menu=host._my_marks_menu
sort(2);expect(visible_ids()=='f,b','bookmark-only view did not sort within its filter')
sort(4);expect(visible_ids()=='f,b','bookmark chapter ordering failed')
expect(value.writes==0 and not value.started,'bookmark sorting accessed storage or network')
Marks.cancel(host)

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
expect(not Marks.show(host,'CB_') and not Marks.show(host,'MP_WXS_synthetic'),'unsupported book type opened')
local cb=snapshot();cb.book_id='CB_Synthetic'
host,value=fixture(cb)
expect(Marks.show(host,'CB_Synthetic') and not value.started,'imported-book highlights did not open offline')
menu=host._my_marks_menu
expect(row(menu,'Local thought drafts') and row(menu,'Check last thought change') and row(menu,'Check last cloud mark change'),
    'imported book hid draft or recovery')
expect(row(menu,'Imported book highlights support private thoughts, saving, deletion, style and color changes after verification.').select_enabled==false,
    'imported-book editing limitation was not visible')
row(menu,'合成引用').callback()
expect(menu._shelf_popup.text=='合成章节\n\n合成引用' and #menu._shelf_popup.buttons_table==4
    and menu._shelf_popup.buttons_table[1][1].id=='open_highlight'
    and menu._shelf_popup.buttons_table[2][1].id=='delete_highlight' and menu._shelf_popup.buttons_table[3][1].id=='thought_create'
    and menu._shelf_popup.buttons_table[4][1].id=='excerpt_card',
    'imported-book highlight did not expose verified actions')
Marks.cancel(host)
cb.updated[1].style=1;cb.updated[1].colorStyle=0
host=fixture(cb);expect(Marks.show(host,'CB_Synthetic'),'imported styled highlight did not open')
menu=host._my_marks_menu;row(menu,'合成引用').callback()
expect(#menu._shelf_popup.buttons_table==6 and menu._shelf_popup.buttons_table[3][1].id=='change_highlight_style'
    and menu._shelf_popup.buttons_table[4][1].id=='change_highlight_color',
    'verified imported style action was hidden')
Marks.cancel(host)
cb.updated[1].colorStyle=3
host=fixture(cb);expect(Marks.show(host,'CB_Synthetic'),'imported colored highlight did not open')
menu=host._my_marks_menu;row(menu,'合成引用').callback()
expect(#menu._shelf_popup.buttons_table==6 and menu._shelf_popup.buttons_table[3][1].id=='change_highlight_style'
    and menu._shelf_popup.buttons_table[4][1].id=='change_highlight_color','imported colored marker lost style or color editing')
Marks.cancel(host)
cb.updated[1].style=2
host=fixture(cb);expect(Marks.show(host,'CB_Synthetic'),'imported colored wavy highlight did not open')
menu=host._my_marks_menu;row(menu,'合成引用').callback()
expect(#menu._shelf_popup.buttons_table==6 and menu._shelf_popup.buttons_table[3][1].id=='change_highlight_style'
    and menu._shelf_popup.buttons_table[4][1].id=='change_highlight_color','imported colored wavy highlight lost editing')
Marks.cancel(host)
cb.updated[2].range='25'
host,value=fixture(cb)
expect(Marks.show(host,'CB_Synthetic','bookmarks') and not value.started,'imported-book bookmarks did not open offline')
menu=host._my_marks_menu;row(menu,'合成章节').callback()
expect(#menu._shelf_popup.buttons_table==1 and menu._shelf_popup.buttons_table[1][1].id=='delete_bookmark',
    'imported-book bookmark exposed unverified navigation or hid deletion')
Marks.cancel(host)
cb.updated[2].markText='独一无二的导入书书签原文预览文字。'
host=fixture(cb)
expect(Marks.show(host,'CB_Synthetic','bookmarks'),'imported-book bookmarks did not reopen')
menu=host._my_marks_menu;row(menu,cb.updated[2].markText).callback()
expect(#menu._shelf_popup.buttons_table==2 and menu._shelf_popup.buttons_table[1][1].id=='open_bookmark'
    and menu._shelf_popup.buttons_table[2][1].id=='delete_bookmark',
    'imported-book bookmark did not expose source-verified navigation and deletion')
Marks.cancel(host)
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
    {reviewId='synthetic-thought-a',content='My quoted thought',abstract='Quoted source',isPrivate=1,chapterName='Chapter',type=1,chapterUid=7,range='12-25',createTime=100,chapterIdx=3},
    {reviewId='synthetic-thought-b',content='My standalone thought',abstract='',chapterName='Chapter',createTime=200,chapterIdx=1},
    {reviewId='synthetic-thought-c',content='',abstract='Only source'}}}
package.loaded['weread.lib.my_cloud_thoughts']={capture=Data.capture,matches=Data.matches,validate=Data.validate,EXPIRED='my_thoughts/native_expired'}
expect(Marks.show(host,'900001','thoughts'),'thought adapter did not open')
menu=host._my_marks_menu;expect(menu.title=='My cloud thoughts','thought mode retained the highlight title')
row(menu,'Sort saved notes').callback();menu._shelf_popup.buttons[2][1].callback()
expect(visible_ids()=='synthetic-thought-b,synthetic-thought-a,synthetic-thought-c','thought time ordering failed')
row(menu,'Sort saved notes').callback();menu._shelf_popup.buttons[4][1].callback()
expect(visible_ids()=='synthetic-thought-b,synthetic-thought-a,synthetic-thought-c','thought chapter ordering failed')
row(menu,'Search saved notes').callback();local thought_search=menu._shelf_popup
thought_search.input='quoted SOURCE';thought_search.buttons[1][2].callback()
expect(row(menu,'My quoted thought') and not pcall(row,menu,'My standalone thought'),'thought search missed quote or leaked unrelated entry')
row(menu,'Search saved notes').callback();menu._shelf_popup.buttons[1][1].callback()
row(menu,'Thoughts with quoted text').callback()
expect(row(menu,'My quoted thought') and not pcall(row,menu,'My standalone thought'),'thought quote filter used the review type')
row(menu,'My quoted thought').callback()
expect(menu._shelf_popup.title=='Private thought' and menu._shelf_popup.text=='Chapter\n\nQuoted text\nQuoted source\n\nThought\nMy quoted thought','thought popup omitted quote or private state')
expect(menu._shelf_popup.buttons_table[1][1].id=='open_thought_quote','supported thought quote lost native original-text action')
UI:close(menu._shelf_popup);row(menu,'Only source').callback()
expect(menu._shelf_popup.text:find('No thought text was returned.',1,true),'quoted-only thought hid its missing body')
expect(#menu._shelf_popup.buttons_table==1 and menu._shelf_popup.buttons_table[1][1].id=='excerpt_card',
    'quote without source range should only expose the local excerpt action')
UI:close(menu._shelf_popup);row(menu,'Other thoughts').callback()
expect(row(menu,'My standalone thought') and not pcall(row,menu,'My quoted thought'),'standalone thought filter failed')
local old_refresh=row(menu,'Refresh my cloud thoughts').callback
value.online=true;old_refresh();local old_complete=value.complete
value.saved=snapshot();Marks.show(host,'900001');local replacement=host._my_marks_menu
old_refresh();old_complete({schema=1,book_id='900001',fetched_at=1001,reviews={}})
expect(host._my_marks_menu==replacement and value.writes==0 and not host.busy_message and value.cancelled==1,'old thought result changed a highlight view')
Marks.cancel(host)
host,value=fixture();value.saved={schema=1,book_id='CB_Synthetic',fetched_at=1000,reviews={
    {reviewId='synthetic-thought',content='Imported thought',abstract='Quoted source',isPrivate=1,type=1,chapterUid=7,range='12-25'}}}
expect(Marks.show(host,'CB_Synthetic','thoughts'),'imported-book thoughts did not open')
menu=host._my_marks_menu
expect(row(menu,'Check last thought change'),'imported-book thought recovery missing')
row(menu,'Imported thought').callback()
expect(#menu._shelf_popup.buttons_table==4 and menu._shelf_popup.buttons_table[1][1].id=='open_thought_quote'
    and menu._shelf_popup.buttons_table[2][1].id=='thought_edit' and menu._shelf_popup.buttons_table[3][1].id=='thought_delete'
    and menu._shelf_popup.text:find('Imported thought',1,true),
    'imported-book private thought did not expose verified actions')
Marks.cancel(host)
host,value=fixture();value.saved={schema=1,book_id='CB_Synthetic',fetched_at=1000,reviews={
    {reviewId='synthetic-public',content='Imported public thought',abstract='Quote',isPrivate=0,type=1,chapterUid=7,range='12-25'}}}
expect(Marks.show(host,'CB_Synthetic','thoughts'),'imported public thought did not open')
menu=host._my_marks_menu;row(menu,'Imported public thought').callback()
expect(#menu._shelf_popup.buttons_table==2 and menu._shelf_popup.buttons_table[1][1].id=='open_thought_quote'
    and menu._shelf_popup.buttons_table[2][1].id=='excerpt_card',
    'unverified imported public thought write was exposed')
Marks.cancel(host)
local bookmark_view=snapshot();bookmark_view.updated[2].range='25'
host,value=fixture(bookmark_view)
bookmark_view.chapters={};host.library_db.getChapters=function() return {{chapterUid='7',title='缓存章节'}} end
expect(Marks.show(host,'900001','bookmarks'),'offline bookmark view rejected')
menu=host._my_marks_menu
expect(menu.title=='My cloud bookmarks' and host._my_marks_owner.filter==0,'bookmark scope/title lost')
expect(not pcall(row,menu,'All cloud marks') and not pcall(row,menu,'合成引用'),'bookmark view exposed other types')
row(menu,'Search saved notes').callback();local bookmark_search=menu._shelf_popup
bookmark_search.input='缓存章节';bookmark_search.buttons[1][2].callback()
expect(row(menu,'缓存章节') and not pcall(row,menu,'合成引用'),'bookmark search escaped its type or missed the cached chapter')
row(menu,'缓存章节').callback()
expect(menu._shelf_popup.buttons_table[1][1].id=='open_bookmark' and menu._shelf_popup.buttons_table[2][1].id=='delete_bookmark','point without preview lost actions')
expect(menu._shelf_popup.text:find('No saved quote text.',1,true),'missing server preview synthesized')
Marks.cancel(host)
expect(not Marks.show(host,'900001','untrusted_table'),'arbitrary personal note mode accepted')
-- Cross-book draft restoration resumes only after the owned reference is
-- available; a user action during refresh invalidates the handoff.
local original_editor=package.loaded['weread.ui.thought_editor']
local resumes={}
package.loaded['weread.ui.thought_editor']={cancel=function() end,resume=function(_host,owner,key,token)
    resumes[#resumes+1]={owner=owner,key=key,token=token};return true end}
local request={book_id='900001',key=string.rep('a',64),token=string.rep('b',32),operation='create',selection=false}
host,value=fixture(snapshot());resumes={}
expect(Marks.show(host,'900001',nil,{resume_draft=request}) and #resumes==1 and resumes[1].key==request.key,
    'cached reference did not start the requested draft')
Marks.cancel(host)
host,value=fixture();resumes={};expect(Marks.show(host,'900001',nil,{resume_draft=request}), 'offline target did not open')
expect(#resumes==0 and value.link_checks==1 and not value.started and #value.notices==1,'missing offline reference was guessed')
Marks.cancel(host)
host,value=fixture();resumes={};request.selection=true
expect(Marks.show(host,'900001',nil,{resume_draft=request}) and #resumes==1 and not value.started,
    'selection draft did not use local source without network')
Marks.cancel(host);request.selection=false
host,value=fixture();value.online=true;resumes={}
expect(Marks.show(host,'900001',nil,{resume_draft=request}) and value.link_checks==1 and value.started==1 and #resumes==0,
    'missing reference did not refresh after one link check')
value.complete(snapshot());expect(value.writes==1 and #resumes==1 and resumes[1].token==request.token,'fresh reference did not resume draft')
Marks.cancel(host)
host,value=fixture();value.online=true;resumes={};Marks.show(host,'900001',nil,{resume_draft=request});menu=host._my_marks_menu
row(menu,'Highlights only').callback();value.complete(snapshot())
expect(#resumes==0 and value.writes==1,'late reference refresh displaced a newer user action')
Marks.cancel(host)
host,value=fixture();value.online=true;resumes={};Marks.show(host,'900001',nil,{resume_draft=request});menu=host._my_marks_menu
menu._shelf_popup={};value.complete(snapshot())
expect(#resumes==0,'late reference refresh opened an editor over another popup')
Marks.cancel(host)
host,value=fixture(snapshot());request.book_id='900002'
expect(not Marks.show(host,'900001',nil,{resume_draft=request}),'another book request was accepted')
package.loaded['weread.ui.thought_editor']=original_editor
print('PASS: own marks native UI ownership, filters, cache and cancellation ('..checks..' checks)')
