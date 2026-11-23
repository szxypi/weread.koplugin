package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local tasks,shown,closed={},nil,0
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_,_,task) tasks[#tasks+1]=task end,
    unschedule=function(_,task) for i=#tasks,1,-1 do if tasks[i]==task then table.remove(tasks,i) end end end,
    show=function(_,dialog) shown=dialog end,
    close=function(_,dialog) closed=closed+1;if shown==dialog then shown=nil end end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,options) return options end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,options) return options end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,file) return file=='/native.epub' end} end
package.preload['weread.lib.native_position_contract']=function() return {account_key=function(vid) return vid=='123' and 'owner' end} end
local page=1
package.preload['weread.lib.source_context']=function() return {
    location=function() return {xpointer='xp'..page,page=page,pos=0,view_mode='page'} end,
    same_location=function(a,b) return a and b and a.xpointer==b.xpointer end,
} end
local invoked
package.preload['weread.lib.reader_position']=function() return {goto_xpointer=function(_,point)
    if point=='xp2' then page=2;return true end;return false end} end
package.preload['weread.ui.native_direct_navigation']=function() return {open_position=function(_,action) invoked=action end} end
local saved;local save_fails=false;local lease_allowed=true
package.preload['weread.lib.native_direct_pending']=function() return {
    read=function(_,_,_,_,guard) return guard() and saved or nil end,
    save=function(_,_,_,entry,point,guard)
        if save_fails or not guard() then return false end
        saved={file_id=entry.file_id,book_id=entry.book_id,chapter_uid=entry.chapter_uid,version=entry.book_version,
            source_sha256=entry.source_sha256,key=entry.key,copy=entry.copy,xpointer=point};return true
    end,
    remove=function(_,_,_,_,record,guard)
        if not guard() or not saved or saved.xpointer~=record.xpointer then return false end
        saved=nil;return true
    end,
} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(doc) return doc.identity end} end
package.preload['weread.lib.native_direct_cache']=function() return {acquire=function()
    if lease_allowed then return {owns=function() return true end,release=function() end} end end,
    valid_entry=function(entry,id,vid) return entry and entry.book_id==id and vid=='123' end} end
local Reconnect=require('weread.ui.native_direct_reconnect')
local function fixture(connected,enabled)
    tasks={};shown=nil;closed=0;invoked=nil;page=1
    local state={online=connected,enabled=enabled,account='owner',scope={vid='123',epoch=1},account_checks=0}
    local host={ui={document={file='/native.epub'},view={view_mode='page'}},_reader_session_gen=1,
        library_db={accountKey=function() return state.account end},
        settings={get_auth_scope=function() return state.scope end,auth_scope_matches=function(_,scope)
            state.account_checks=state.account_checks+1;return state.scope==scope end,
            get=function() return {pull_on_open=state.enabled} end},isNetworkConnected=function() return state.online end,
        showInfo=function(_,message) state.message=message end}
    return host,state
end
local function pump() local task=table.remove(tasks,1);assert(task);task() end
local host,s=fixture(true,true);expect(Reconnect.ready(host),'ready failed');Reconnect.disconnected(host);s.online=false
page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);Reconnect.connected(host)
expect(#tasks==1 and not shown,'duplicate connection did not deduplicate');pump()
expect(shown and #shown.buttons==3 and not invoked,'offline change did not show the choice')
shown.buttons[1][1].callback();expect(invoked=='cloud' and not shown,'cloud comparison was not selected')
host,s=fixture(false,true);expect(Reconnect.ready(host));page=3;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
shown.buttons[2][1].callback();expect(invoked=='upload','manual position upload was not selected')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
shown.buttons[3][1].callback();expect(not invoked and not shown,'later triggered a position action')
host,s=fixture(false,false);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host)
expect(#tasks==0,'disabled automatic pull displayed a reconnect prompt')
host,s=fixture(false,true);Reconnect.ready(host);s.online=true;Reconnect.connected(host)
expect(#tasks==0,'unchanged page displayed a reconnect prompt')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);page=1;Reconnect.view_changed(host)
s.online=true;Reconnect.connected(host);expect(#tasks==0,'returning to the original page displayed a prompt')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
local callback=shown.buttons[2][1].callback;page=3;Reconnect.view_changed(host);callback()
expect(not invoked and not shown and closed==1,'stale page could trigger an upload')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
callback=shown.buttons[2][1].callback;s.account='other';callback();expect(not invoked,'stale account could trigger an upload')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
callback=shown.buttons[1][1].callback;s.online=false;callback();expect(not invoked,'offline confirmation started a cloud request')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);host._weread_suspended=true;s.online=true
Reconnect.connected(host);expect(#tasks==0,'prompt appeared during suspend');host._weread_suspended=nil;Reconnect.connected(host);pump()
expect(shown~=nil,'reconnection during suspend was not offered after resume')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host)
Reconnect.cancel(host);expect(#tasks==0 and not host._native_direct_reconnect,'closing did not cancel pending reminder')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
Reconnect.suspend(host);host._weread_suspended=true;expect(not shown,'suspend left the reminder open')
host._weread_suspended=nil;Reconnect.connected(host);pump();expect(shown~=nil,'suspend lost the unanswered reminder')
host,s=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
callback=shown.buttons[2][1].callback;s.enabled=false;callback();expect(not invoked,'disabled pull allowed an old reminder')
host,s=fixture(false,true);Reconnect.ready(host);local checks_before=s.account_checks
page=2;Reconnect.view_changed(host);expect(s.account_checks==checks_before,'page event reread account state')
s.account='other';s.online=true;Reconnect.connected(host)
expect(#tasks==0 and not host._native_direct_reconnect,'changed account reached the reconnect prompt')
local entry={book_id='42',chapter_uid='3',file_id='file',book_version=1,source_sha256='source',key='key',copy=0}
host=fixture(false,false);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);Reconnect.bind(host,entry);page=2;Reconnect.view_changed(host)
expect(Reconnect.checkpoint(host)==true and saved and saved.xpointer=='xp2','offline page was not recorded on close')
Reconnect.cancel(host)
host=fixture(true,true);page=2;host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);Reconnect.bind(host,entry,saved);pump()
expect(shown~=nil,'reopened matching page did not offer the saved reminder')
Reconnect.view_changed(host);expect(shown~=nil,'unchanged page event closed the saved reminder')
shown.buttons[4][1].callback();expect(saved~=nil,'later deleted the saved reminder')
Reconnect.synced(host,entry,{xpointer='xp2'});expect(saved==nil,'confirmed sync did not clear the matching reminder')
host,s=fixture(false,false);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
Reconnect.ready(host);Reconnect.bind(host,entry);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host)
expect(saved and saved.xpointer=='xp2' and #tasks==0,'disabled pull lost the offline checkpoint')
saved=nil
host=fixture(false,true);Reconnect.ready(host);page=2;Reconnect.view_changed(host)
expect(Reconnect.checkpoint(host)==false,'unverified chapter silently saved a reminder')
host=fixture(false,false);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
Reconnect.ready(host);Reconnect.bind(host,entry);page=2;Reconnect.view_changed(host);assert(Reconnect.checkpoint(host));Reconnect.cancel(host)
host=fixture(true,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
host.ui.document.isXPointerInDocument=function(_,point) return point=='xp2' end
Reconnect.ready(host);Reconnect.bind(host,entry,saved);pump()
expect(shown and shown.buttons[1][1].id=='reconnect_restore','different page did not offer the offline position')
shown.buttons[1][1].callback();pump()
expect(page==2 and shown and shown.buttons[1][1].id=='reconnect_cloud' and saved,
    'restoring the offline position did not offer comparison while retaining its reminder')
Reconnect.cancel(host)
host,s=fixture(true,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
host.ui.document.isXPointerInDocument=function() return true end
Reconnect.ready(host);Reconnect.bind(host,entry,saved);pump();callback=shown.buttons[1][1].callback
s.account='other';callback();expect(page==1 and saved,'stale account opened a saved position')
host,s=fixture(false,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);Reconnect.bind(host,entry,saved);page=3;Reconnect.view_changed(host);save_fails=true
s.online=true;Reconnect.connected(host);pump()
expect(shown and shown.buttons[1][1].id=='reconnect_cloud' and saved.xpointer=='xp2',
    'failed checkpoint displaced the current offline page with an older reminder')
save_fails=false;Reconnect.cancel(host)
host=fixture(false,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
Reconnect.ready(host);Reconnect.bind(host,entry,saved);page=3;Reconnect.view_changed(host);lease_allowed=false
expect(Reconnect.checkpoint(host)==false and saved.xpointer=='xp2','cache lease conflict overwrote an offline reminder')
lease_allowed=true
local function saved_fixture()
    local h,state=fixture(true,true);page=2
    h.ui.document.identity={book_id='42',file_id='file',book_version=1}
    h.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
    state.messages={};h.showInfo=function(_,message) state.messages[#state.messages+1]=message end
    Reconnect.ready(h);Reconnect.bind(h,entry,saved);pump()
    return h,state
end
host,s=saved_fixture();expect(shown.buttons[3][1].id=='reconnect_discard','saved reminder had no discard action')
shown.buttons[3][1].callback();expect(saved and shown.ok_callback and shown.cancel_callback,'discard skipped confirmation')
shown.cancel_callback();expect(saved and #s.messages==0,'cancel removed the reminder')
Reconnect.cancel(host)
host,s=saved_fixture();shown.buttons[3][1].callback();callback=shown.ok_callback;page=3;Reconnect.view_changed(host);callback()
expect(saved and #s.messages==0,'stale page removed a reminder')
Reconnect.cancel(host)
host,s=saved_fixture();shown.buttons[3][1].callback();callback=shown.ok_callback;s.account='other';callback()
expect(saved and #s.messages==0,'changed account removed a reminder')
Reconnect.cancel(host)
host,s=saved_fixture();shown.buttons[3][1].callback();host._native_direct_reconnect.pending_dirty=true;shown.ok_callback()
expect(saved and #s.messages==0,'new unsaved position allowed the old reminder to be removed')
Reconnect.cancel(host)
host,s=saved_fixture();shown.buttons[3][1].callback();local newer={};for key,value in pairs(saved) do newer[key]=value end
newer.xpointer='xp3';saved=newer;shown.ok_callback()
expect(saved and saved.xpointer=='xp3' and s.messages[1]=='Could not remove the offline reminder. It was kept.',
    'changed reminder was removed or reported successful')
saved.xpointer='xp2';Reconnect.cancel(host)
host,s=saved_fixture();shown.buttons[3][1].callback();shown.ok_callback()
expect(not saved and not host._native_direct_reconnect.record and s.messages[1]=='Offline reminder removed.' and page==2 and not invoked,
    'confirmed removal changed page or failed to remove the reminder')
saved={file_id=entry.file_id,book_id=entry.book_id,chapter_uid=entry.chapter_uid,version=entry.book_version,
    source_sha256=entry.source_sha256,key=entry.key,copy=entry.copy,xpointer='xp2'}
host=fixture(true,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);Reconnect.bind(host,entry,saved);pump()
expect(shown.buttons[2][1].id=='reconnect_discard','different page omitted the discard action')
shown.buttons[2][1].callback();shown.ok_callback()
expect(not saved and page==1 and not invoked,'discarding another page moved the reader or contacted the cloud')
saved={file_id=entry.file_id,book_id=entry.book_id,chapter_uid=entry.chapter_uid,version=entry.book_version,
    source_sha256=entry.source_sha256,key=entry.key,copy=entry.copy,xpointer='xp2'}
host=fixture(false,false);page=2;host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);expect(Reconnect.open_manual(host,entry,saved),'offline manual reminder did not open');pump()
expect(#shown.buttons==2 and shown.buttons[1][1].id=='reconnect_discard',
    'offline manual reminder offered cloud actions or hid local removal')
shown.buttons[1][1].callback();shown.ok_callback()
expect(not saved and page==2 and not invoked and Reconnect.checkpoint(host)==nil,
    'offline removal changed the page or recreated the removed reminder')
host=fixture(false,false);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);page=2;Reconnect.view_changed(host)
expect(Reconnect.open_manual(host,entry,nil) and saved and saved.xpointer=='xp2',
    'manual review did not save a new offline page');pump()
expect(shown.buttons[1][1].id=='reconnect_discard' and not host._native_direct_reconnect.dirty,
    'manual save did not establish a clean local baseline')
shown.buttons[1][1].callback();shown.ok_callback()
expect(not saved and Reconnect.checkpoint(host)==nil,'manual removal recreated the newly saved reminder')
saved={file_id=entry.file_id,book_id=entry.book_id,chapter_uid=entry.chapter_uid,version=entry.book_version,
    source_sha256=entry.source_sha256,key=entry.key,copy=entry.copy,xpointer='xp2'}
Reconnect.cancel(host)
host,s=fixture(false,false);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);page=3;Reconnect.view_changed(host)
expect(not Reconnect.open_manual(host,entry,saved) and saved.xpointer=='xp2'
    and s.message=='Save or sync the current offline page before reviewing the earlier reminder.',
    'manual review overwrote an earlier reminder or moved an unsaved page')
host,s=fixture(true,false);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
host.ui.document.isXPointerInDocument=function(_,point) return point=='xp2' end
Reconnect.ready(host);expect(Reconnect.open_manual(host,entry,saved),'manual review obeyed disabled automatic pull');pump()
expect(shown.buttons[1][1].id=='reconnect_restore','manual review did not offer the old position')
local newer_manual={};for key,value in pairs(saved) do newer_manual[key]=value end;newer_manual.xpointer='xp3';saved=newer_manual
shown.buttons[1][1].callback()
expect(page==1 and s.message=='The saved offline position changed. Please open it again.',
    'manual restore used a stale position')
saved.xpointer='xp2';Reconnect.cancel(host)
host=fixture(true,false);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
host.ui.document.isXPointerInDocument=function(_,point) return point=='xp2' end
Reconnect.ready(host);expect(Reconnect.open_manual(host,entry,saved));pump();shown.buttons[1][1].callback();pump()
expect(page==2 and shown.buttons[1][1].id=='reconnect_cloud','manual restore did not preserve manual mode')
Reconnect.cancel(host)
saved=nil;host,s=fixture(false,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
shown.buttons[3][1].callback();expect(not saved and not shown,'later unexpectedly wrote an unverified chapter')
Reconnect.bind(host,entry,nil)
expect(saved and saved.xpointer=='xp2' and #tasks==0,'late source verification lost or repeated the offline reminder')
Reconnect.cancel(host);saved=nil
host,s=fixture(false,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
Reconnect.ready(host);page=2;Reconnect.view_changed(host);s.online=true;Reconnect.connected(host);pump()
shown.buttons[3][1].callback();page=3;Reconnect.view_changed(host);Reconnect.bind(host,entry,nil)
expect(not saved,'late source verification saved a page that was no longer current')
Reconnect.cancel(host)
host,s=fixture(false,true);host.ui.document.identity={book_id='42',file_id='file',book_version=1}
host.ui.document.isXPointerInCurrentPage=function(_,point) return point=='xp'..page end
Reconnect.ready(host);Reconnect.bind(host,entry,nil);page=2;Reconnect.view_changed(host);Reconnect.suspend(host)
expect(saved and saved.xpointer=='xp2' and not host._native_direct_reconnect.dirty,
    'suspend did not checkpoint the offline page')
host._weread_suspended=true;s.online=true;Reconnect.connected(host);expect(#tasks==0,'suspended reconnect showed a prompt')
host._weread_suspended=nil;Reconnect.connected(host);pump()
expect(shown and shown.buttons[1][1].id=='reconnect_cloud','checkpointed offline page was not offered after resume')
Reconnect.cancel(host)
print('PASS: native offline reconnect choices and session guards ('..checks..' checks)')
