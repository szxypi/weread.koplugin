package.path='./?.lua;'..package.path
local UI={close=function(_self,view) view.closed=true;if view.onCloseWidget then view:onCloseWidget() end end,
    show=function(self,view) self.top=view end,nextTick=function(_self,callback) callback() end,
    scheduleIn=function(self,_,callback) self.scheduled=callback end,
    unschedule=function(self,callback) if self.scheduled==callback then self.scheduled=nil end end}
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
    Store.new=function() return {read=function()
        value.reads=(value.reads or 0)+1
        if value.on_read then value.on_read() end
        return value.saved
    end,write=function(_self,row)
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
    for _,item in ipairs(menu.item_table) do
        local text=item.text_func and item.text_func() or item.text
        if text==label then return item end
    end
    error('missing row '..label)
end
do
    local notes=snapshot()
    local prefix=string.rep('字',77)
    notes.updated[1].markText=prefix..'\t😀\n'..'完整正文'
    local host=fixture(notes)
    local protocol=require('weread.lib.protocol')
    local substr=protocol.utf8_substr
    local previews=0
    protocol.utf8_substr=function(value,limit)
        if limit==80 then previews=previews+1 end
        return substr(value,limit)
    end
    expect(Marks.show(host,'900001') and previews==0,'building the list eagerly formatted note labels')
    local menu=host._my_marks_menu
    local item=assert(row(menu,prefix..' 😀 '))
    expect(item.text_func()==prefix..' 😀 ' and previews==1,'preview split Unicode, kept controls, or recomputed the label')
    item.callback()
    expect(menu._shelf_popup.text:find(notes.updated[1].markText,1,true),'truncated label replaced the original note')
    UI:close(menu._shelf_popup)
    row(menu,'Highlights only').callback()
    expect(row(menu,prefix..' 😀 ').text_func()==prefix..' 😀 ' and previews==1,'filtering recomputed a displayed preview')
    Marks.cancel(host)
    protocol.utf8_substr=substr
end
do
    local host,state=fixture(snapshot())
    local initial_note='synthetic-1'
    local source,opened={},nil
    local function valid() return not source.closed end
    local function done(result) opened=result end
    local function select(note) opened=nil;return Marks.open_saved(host,'900001','marks',note,source,valid,done) end
    expect(select(initial_note) and not state.reads and not host.busy_message,'saved result read on the UI thread or showed an immediate dialog')
    state.complete(state.task())
    expect(opened and state.reads==1 and not UI.scheduled,'opening a saved result reread the note cache or queued a dialog')
    local menu=host._my_marks_menu
    expect(menu._shelf_popup.text=='合成章节\n\n合成引用','saved result opened the wrong note')
    state.online=true
    expect(select('missing'),'missing saved result did not start its check')
    state.complete(state.task())
    expect(opened==false and not state.link_checks
        and host._my_marks_menu==menu,'missing result replaced the active view or checked the network')
    Marks.cancel(host)
    state.saved=nil
    expect(select(initial_note),'absent saved result did not start its check')
    state.complete(state.task())
    expect(opened==false and not state.link_checks
        and not host._my_marks_owner,'an absent saved cache started a refresh or opened an empty view')
    expect(not select('bad id') and state.reads==3,
        'an invalid note identity read the cache')
    state.saved=snapshot()
    expect(select(initial_note),'stale-scope check did not start')
    state.on_read=function() state.account='different' end
    state.complete(state.task())
    expect(opened==nil and not host._my_marks_owner and not source.saved_note_open,
        'an account change during the cache read opened a stale result')
end
do
    local host,state=fixture(snapshot());state.online=true
    local source,opened={},nil
    local function valid() return not source.closed end
    local function done(result) opened=result end
    local function open(variant) opened=nil;return Marks.open_saved_book(host,'900001',variant,source,valid,done) end
    expect(open('bookmarks') and open('bookmarks')==false and state.started==1,'saved notebook started duplicate reads')
    local complete,task=state.complete,state.task
    UI.scheduled()
    local cancel=host.busy_message.cancel
    cancel()
    expect(open('bookmarks'),'cancelled notebook could not be retried')
    cancel();complete(task())
    expect(not host._my_marks_owner and opened==nil and source.saved_note_open,'an old reading job altered a retry')
    state.complete(state.task())
    expect(opened and host._my_marks_owner.bookmarks and not state.link_checks and not host.busy_message,
        'saved book did not open its local bookmark snapshot')
    local prior=host._my_marks_owner
    state.saved=nil
    expect(open('thoughts'),'missing saved notebook did not start its check')
    state.complete(state.task())
    expect(opened==false and host._my_marks_owner==prior and not state.link_checks,'missing saved book started a cloud refresh')
    expect(open('bookmarks'),'saved notebook close check did not start')
    source.closed=true
    Marks.cancel_saved(host,source)
    state.complete(snapshot())
    expect(opened==nil and not source.saved_note_open and host._my_marks_owner==prior,'closed source opened a stale notebook')
    Marks.cancel(host)
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
local Order=require('weread.lib.personal_notes_order')
local original_order=Order.rows
local sorts=0
Order.rows=function(...)
    sorts=sorts+1
    return original_order(...)
end
sort(2);expect(visible_ids()=='a,d,b,c,e','newest order or stable ties were wrong')
stale_note();expect(not menu._shelf_popup,'old note action survived a new ordering')
sort(3);expect(visible_ids()=='b,a,d,c,e','oldest order or missing dates were wrong')
sort(4);expect(visible_ids()=='d,e,a,b,c','chapter order or missing chapter was wrong')
row(menu,'Highlights only').callback();expect(visible_ids()=='d,e,a,c','sort ignored the selected type')
row(menu,'Search saved notes').callback();local sorted_search=menu._shelf_popup
sorted_search.input='match a';sorted_search.buttons[1][2].callback()
expect(visible_ids()=='a' and row(menu,'Sort saved notes').mandatory=='Chapter order','search reset the ordering')
expect(sorts==3,'filtering or searching repeated the saved note sort')
Order.rows=original_order
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
bookmark_view.chapters={}
local title_reads=0
host.library_db.getChapterTitles=function(_self,id,ids)
    title_reads=title_reads+1
    assert(id=='900001' and #ids==1 and ids[1]=='7')
    return {['7']='缓存章节'}
end
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
expect(title_reads==1,'searching existing notes repeated the chapter title lookup')
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

do
    local notes=snapshot();notes.updated={}
    for index=1,5000 do
        notes.updated[index]={bookmarkId='large-note-'..index,type=index%2,
            markText='Unicode 示例 😀 needle '..index,createTime=index}
    end
    local Search=require('weread.lib.shelf_search')
    local find,comparisons=Search.find,0
    Search.find=function(text,...)
        if type(text)=='string' then comparisons=comparisons+1 end
        return find(text,...)
    end
    local large,state=fixture(notes)
    expect(Marks.show(large,'900001'),'large saved list did not open')
    local list=large._my_marks_menu
    row(list,'Search saved notes').callback()
    local dialog=list._shelf_popup;dialog.input='needle';dialog.buttons[1][2].callback()
    expect(state.started==1 and comparisons==0 and large.busy_message,'large query blocked on the interface')
    state.complete(state.task())
    expect(comparisons==5000,'large query did not check every row')
    row(list,'Highlights only').callback()
    row(list,'Sort saved notes').callback()
    list._shelf_popup.buttons[2][1].callback()
    row(list,'All cloud marks').callback()
    expect(comparisons==5000,'changing type or order rescanned the same query')
    row(list,'Search saved notes').callback()
    dialog=list._shelf_popup;dialog.input='needle 5000';dialog.buttons[1][2].callback()
    local late,abandoned=state.complete,state.task
    large.busy_message.cancel()
    late(abandoned())
    expect(not large.busy_message and large._my_marks_owner.search=='needle','cancelled search replaced the previous results')
    comparisons=5000
    row(list,'Search saved notes').callback()
    dialog=list._shelf_popup;dialog.input='needle 5000';dialog.buttons[1][2].callback()
    state.complete(state.task())
    expect(comparisons==10000 and row(list,notes.updated[5000].markText),'new query reused outdated matches')
    row(list,'Highlights only').callback()
    expect(row(list,'No matching notes in this view.'),'new query lost the highlight filter')
    row(list,'All cloud marks').callback()
    expect(comparisons==10000,'non-matching rows were searched again')
    state.online=true
    row(list,'Refresh my cloud marks').callback()
    local refreshed=snapshot()
    refreshed.updated={{bookmarkId='large-note-5000',type=0,markText='Updated needle 5000'}}
    state.complete(refreshed)
    expect(comparisons==10001 and row(list,'Updated needle 5000')
        and not pcall(row,list,notes.updated[5000].markText),'refresh retained results or a preview from the old snapshot')
    row(list,'Refresh my cloud marks').callback()
    state.complete(notes)
    expect(large._my_marks_owner.note_search_job and comparisons==10001,
        'refreshing a large snapshot blocked while applying the active query')
    state.complete(state.task())
    expect(comparisons==15001 and row(list,notes.updated[5000].markText),'updated snapshot did not reapply the active search')
    row(list,'Search saved notes').callback()
    dialog=list._shelf_popup;dialog.input='stale query';dialog.buttons[1][2].callback()
    late=state.complete
    state.account='different'
    late({flags=string.rep('0',5000)})
    expect(not large.busy_message and large._my_marks_owner.search=='needle 5000','a previous account search changed the list')
    Marks.cancel(large)
    Search.find=find
end
do
    local note=snapshot()
    note.updated[1].markText=string.rep('字',23000)..'needle'
    local small,state=fixture(note)
    expect(Marks.show(small,'900001'),'single long note list did not open')
    local list=small._my_marks_menu
    row(list,'Search saved notes').callback()
    local dialog=list._shelf_popup
    dialog.input='needle';dialog.buttons[1][2].callback()
    expect(state.started==1 and small.busy_message,'long text was scanned by the interface')
    state.complete({flags='not a result'})
    expect(not small.busy_message and not small._my_marks_owner.search and #state.notices==1,
        'malformed response replaced the collection')
    Marks.cancel(small)
end
print('PASS: own marks native UI ownership, filters, cache and cancellation ('..checks..' checks)')
