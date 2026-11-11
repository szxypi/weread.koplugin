package.path='./?.lua;'..package.path
local UI={tasks={},show=function(self,v) self.top=v end,close=function(_self,v) v.closed=true end,
    scheduleIn=function(self,delay,task) assert(delay>=0.1);self.tasks[task]=true end,
    unschedule=function(self,task) self.tasks[task]=nil end}
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,v) return v end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
local Target=require('weread.lib.my_mark_target')
local Bookmark=require('weread.lib.my_bookmark_target')
local Nav=require('weread.ui.my_mark_navigation')
local Context=require('weread.lib.source_context')
local Auth=require('weread.lib.worker_settings')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function position() return {book_id='41',chapter_uid='2',chapter_offset=15,basis='filtered_xhtml_utf16',upload_verified=false} end
local function bound(path) return {file=path or '/cached.epub',position=position(),identity={book_id='41',file_id=string.rep('a',64)},request_id=1} end
local function fixture(reader,thoughts)
    local f={valid=true,account='account',scope={},online=true,works={},starts=0,cancels=0,notices={},location={page=1},frame={},nav_generation=0}
    local owner={id='41',account=f.account,scope=f.scope,value={},thoughts=thoughts}
    local host={settings={},library_db={},ui={},_reader_session_gen=0,progress_sync={},source_navigation={}}
    host.ui.weread=host
    if reader then host.ui.document={file='/cached.epub'};host._reader_session_gen=1 end
    host.settings.get_book=function() return {book_id='41',cached_file='/cached.epub'} end
    host.settings.auth_scope_matches=function(_self,scope) return f.valid and scope==f.scope end
    host.library_db.accountKey=function() return f.account end
    host.library_db.putChapters=function() f.catalog_saved=true;return true end
    host.isNetworkOnline=function() return f.online end
    host.requireLogin=function() return f.login~=false end
    host.showInfo=function(_self,v) f.notices[#f.notices+1]=v end
    host.showBusy=function(_self,_text,cancel) host.busy_message={cancel=cancel} end
    host.closeBusy=function() host.busy_message=nil end
    host.detectWeReadBook=function() return '41' end
    host.closeWeReadUI=function() f.closed=true;Nav.cancel(host,owner) end
    host.openFile=function(_self,path,callback) f.opened=path;f.receive=callback;host:closeWeReadUI() end
    host.progress_sync.navigation_generation=0
    host.progress_sync.begin_file_resume=function() f.begin=(f.begin or 0)+1;return f.frame end
    host.progress_sync.finish_file_resume=function(_self,frame,applied) assert(frame==f.frame);f.finished=applied;return true end
    host.progress_sync.begin_file_resume_departure=function() f.departed=true end
    host.openSourcePosition=function(_self,target,callback) f.jumped=target;f.applied=callback;host.source_navigation.job={};return true end
    host.downloader={}
    host.downloader.start=function(_self,book,chapters,_suffix,options)
        f.downloads=(f.downloads or 0)+1;f.options=options;f.download_chapter=chapters[1];f.download_book=book
        host.downloader._active_job={};return true
    end
    host.downloader.cancelJob=function(_self,job) f.download_cancelled=job end
    Context.location=function() return f.location end
    Auth.fingerprint=function() return f.fingerprint or 'same' end
    Auth.capture=function() return function() return nil end end
    Auth.merge=function() return f.merge~=false end
    package.loaded['weread.lib.content']={ensure_reader_state=function() f.reader_read=true end,
        fetch_catalog=function() return {{chapterUid='2',title='Target',chapterIdx=2,wordCount=200}} end,
        save_catalog_cache=function() return f.save~=false end}
    Target.resolve=function() return f.missing and {error='my_mark_target/source_unavailable',request_id=1} or bound() end
    Target.bind_file=function(path) return f.bad_download and {request_id=1,error='my_mark_target/quote_changed'} or bound(path) end
    package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_self,task,done)
        f.starts=f.starts+1;f.works[#f.works+1]={task=task,done=done};return f.start~=false
    end,cancel=function() f.cancels=f.cancels+1 end} end}
    local function current() return f.current~=false and f.valid and f.account==owner.account end
    f.row=thoughts and {reviewId='synthetic-review',type=1,chapterUid=2,abstract='Unique selected text',content='Separate prose',range='15-35'}
        or {type=1,chapterUid=2,markText='Unique selected text',range='15-35'}
    local function start() return Nav.start(host,owner,f.row,current) end
    local function complete(index) local item=f.works[index or #f.works];item.done(item.task()) end
    return host,owner,f,start,complete
end
local host,owner,f,start,complete=fixture(true)
Bookmark.resolve=function(...) return Target.resolve(...) end
Bookmark.bind_file=function(...) return Target.bind_file(...) end
f.row={type=0,chapterUid=2,range='15',bookmarkId='synthetic-point'}
expect(start(),'bookmark without preview did not start');complete()
expect(f.jumped and f.jumped.chapter_offset==15 and f.jumped.upload_verified==false,'bookmark used wrong position path')
f.applied(position())
expect(not owner.navigation and not host._read_resume_active,'bookmark retained finished navigation')
host,owner,f,start,complete=fixture(true);f.row={type=0,chapterUid=2,range='15',bookmarkId='synthetic-point'}
expect(start(),'bookmark stale guard did not start');f.row.bookmarkId='changed';complete()
expect(not f.jumped and not f.opened and not owner.navigation and not host._read_resume_active,'changed bookmark id navigated')
host,owner,f,start,complete=fixture(true)
expect(start(),'reader lookup did not start');complete()
expect(f.closed and f.jumped and not f.opened and f.begin==1,'same-file jump reopened a file or lost sync gate')
expect(not owner.navigation,'same-file dispatch retained old lookup')
expect(host._read_resume_active and f.finished==nil,'navigation was accepted before native callback')
f.applied(position());expect(f.finished==true and not host._read_resume_active,'verified navigation did not save local result')
host,owner,f,start,complete=fixture(false);start();complete()
expect(f.opened=='/cached.epub' and f.departed and not f.jumped,'file-manager lookup did not defer navigation until open')
expect(not owner.navigation,'file handoff retained old lookup')
local next_host={ui={document={file='/cached.epub'}},settings=host.settings,library_db=host.library_db,
    progress_sync=host.progress_sync,source_navigation={},detectWeReadBook=host.detectWeReadBook,
    openSourcePosition=host.openSourcePosition,showInfo=host.showInfo}
expect(f.receive{weread=next_host,document=next_host.ui.document}==true and f.jumped,'new reader did not accept guarded target')
expect(f.receive{weread=next_host,document=next_host.ui.document}==false,'handoff replayed')
for _i,mode in ipairs({'account','scope','owner','snapshot','location','cancel','replacement'}) do
    host,owner,f,start,complete=fixture(true);start();local old=f.works[1]
    if mode=='account' then f.account='other' elseif mode=='scope' then f.valid=false
    elseif mode=='owner' then f.current=false elseif mode=='snapshot' then owner.value={}
    elseif mode=='location' then f.location={page=2} elseif mode=='cancel' then host.busy_message.cancel()
    else start() end
    old.done(old.task())
    expect(complete~=nil,'replacement callback missing')
    expect(not f.opened and not f.jumped,mode..' accepted an obsolete source result')
    if mode=='replacement' then expect(owner.navigation~=nil,'stale callback cancelled new lookup') end
end
for _i,mode in ipairs({'account','scope','session','book','file','generation'}) do
    host,owner,f,start,complete=fixture(false);start();complete()
    expect(not owner.navigation,'guarded transfer retained its former owner')
    local peer={ui={document={file='/cached.epub'}},settings=host.settings,library_db=host.library_db,
        progress_sync=host.progress_sync,source_navigation={},detectWeReadBook=host.detectWeReadBook,
        openSourcePosition=host.openSourcePosition,showInfo=host.showInfo}
    if mode=='account' then f.account='other' elseif mode=='scope' then f.valid=false
    elseif mode=='session' then host._reader_session_gen=1 elseif mode=='book' then peer.detectWeReadBook=function() return '99' end
    elseif mode=='file' then peer.ui.document.file='/wrong.epub' else peer.progress_sync.navigation_generation=1 end
    expect(f.receive{weread=peer,document=peer.ui.document}==false and not f.jumped,mode..' escaped handoff ownership')
end
host,owner,f,start,complete=fixture(false);f.missing=true;f.online=false;start();complete()
expect(#f.notices==1 and not f.opened and not owner.navigation,'offline failure moved or started a download')
expect(host.busy_message==nil,'offline failure kept busy message')
host,owner,f,start,complete=fixture(false);f.missing=true;start();complete()
local old_confirm=UI.top;expect(old_confirm.ok_callback and not f.downloads,'missing cache downloaded without choice')
start();local replacement=owner.navigation;old_confirm.cancel_callback()
expect(owner.navigation==replacement,'obsolete confirmation cancelled replacement')
complete();UI.top.ok_callback();complete()
expect(host.busy_message==nil,'downloader retained catalog busy message')
expect(f.reader_read and f.catalog_saved and f.downloads==1 and f.download_chapter.chapterUid=='2','confirmed download selected wrong chapter')
expect(f.options.include_annotations==false and f.options.offer_read==false and f.options.single_chapter,'download could open before source validation')
f.options.on_complete(true,'/downloaded.epub')
local pending=owner.navigation.task;expect(UI.tasks[pending],'download opened before downloader released its job')
UI.tasks[pending]=nil;pending();complete()
expect(f.opened=='/downloaded.epub' and not owner.navigation,'verified downloaded chapter did not hand off')
host,owner,f,start,complete=fixture(false);f.missing=true;start();complete();UI.top.ok_callback();complete()
local job=host.downloader._active_job;Nav.cancel(host,owner)
f.options.on_complete(true,'/downloaded.epub')
expect(f.download_cancelled==job and not f.opened,'cancelled download navigated after completion')
for _i,mode in ipairs({'save','login','merge','changed_auth','download_changed'}) do
    host,owner,f,start,complete=fixture(false);f.missing=true;start();complete()
    if mode=='login' then f.login=false end
    UI.top.ok_callback()
    if mode=='save' then f.save=false elseif mode=='changed_auth' then f.fingerprint='changed'
    elseif mode=='merge' then f.merge=false;f.works[#f.works].task=function() return {book_id='41',auth={},chapters={{chapterUid='2',title='Target'}}} end end
    if mode~='login' then complete() end
    if mode=='download_changed' then
        f.bad_download=true;f.options.on_complete(true,'/downloaded.epub');local task=owner.navigation.task;task();complete()
    end
    expect(not f.opened,mode..' opened an unverified download')
    expect(host.busy_message==nil,mode..' kept busy message after failure')
    expect(not owner.navigation,mode..' retained failed lookup')
    if mode~='download_changed' then expect(not f.downloads,mode..' started a download after failed validation') end
end
-- The thought adapter shares the complete native handoff and download path.
host,owner,f,start,complete=fixture(true,true);expect(start(),'quoted thought lookup did not start');complete()
expect(f.jumped and not f.opened and not owner.navigation and not host.busy_message,'thought quote did not use same-file native jump')
f.applied(position());expect(f.finished==true,'thought quote did not preserve local resume state')
host,owner,f,start,complete=fixture(false,true);start();complete()
expect(f.opened=='/cached.epub' and not owner.navigation and not host.busy_message,'thought quote did not hand off cached file')
host,owner,f,start,complete=fixture(false,true);f.missing=true;start();complete()
expect(UI.top.text=='No matching downloaded chapter. Download it and locate this thought quote?','thought confirmation used highlight wording')
UI.top.ok_callback();complete();f.options.on_complete(true,'/downloaded.epub');owner.navigation.task();complete()
expect(f.opened=='/downloaded.epub' and f.options.include_annotations==false and not host.busy_message,'thought download did not rebind exact quote')
for _i,thoughts in ipairs({false,true}) do
    host,owner,f,start,complete=fixture(true,thoughts);start()
    f.row[thoughts and 'abstract' or 'markText']='Changed displayed reference';complete()
    expect(not owner.navigation and not f.jumped and not f.opened and not host.busy_message,'mutated quote kept old navigation task')
end
local missing_host,missing_owner,missing_f,missing_start=fixture(true,true)
missing_f.row.abstract=nil;missing_f.row.markText='Fallback highlight';missing_f.row.content='Fallback thought'
expect(not missing_start() and missing_f.starts==0 and not missing_owner.navigation and not missing_host.busy_message,'missing thought quote fell back to other text')
print('my_mark_navigation_spec: '..checks..' ownership, local navigation, handoff and download checks passed')
