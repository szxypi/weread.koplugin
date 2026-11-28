package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local scheduled
package.preload['ui/uimanager']=function() return {
    close=function(_,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    scheduleIn=function(_,_,task) scheduled[#scheduled+1]=task end,
} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,
    T=function(pattern,value) return (pattern:gsub('%%1',value)) end} end
local source={book_id='42',chapter_uid='37',book_version=1,source_sha256=string.rep('c',64),key=string.rep('a',64),copy=0,
    file_id=string.rep('f',64),missing_images=0,catalog_sha256=string.rep('b',64),catalog_order=2,catalog_count=3,catalog_prev='36',catalog_next='38'}
local next_entry={book_id='42',chapter_uid='38',book_version=1,source_sha256=string.rep('d',64),key=string.rep('e',64),copy=0,
    title='Next',missing_images=2,catalog_sha256=source.catalog_sha256,catalog_order=3,catalog_count=3,catalog_prev='37'}
local full_entry={book_id='42',chapter_uid='38',book_version=1,source_sha256=string.rep('d',64),key=string.rep('f',64),copy=0,
    title='Next',missing_images=0,catalog_sha256=source.catalog_sha256,catalog_order=3,catalog_count=3,catalog_prev='37'}
local rows={next_entry};local source_ok=true;local can_open=true
local listed_uid
local page=1;local in_worker=false
package.preload['weread.lib.source_context']=function() return {
    location=function() assert(not in_worker,'background task accessed reader geometry');return {page=page} end,
    same_location=function(a,b) return a and b and a.page==b.page end,
} end
package.preload['weread.lib.native_direct_cache']=function() return {MAX_ENTRIES=2000,
    valid_entry=function(entry,id,account) return (entry==source or entry==next_entry or entry==full_entry) and id=='42' and account=='123' end,
    identify=function(_,_,_,current) return current() and source_ok and source or nil end,
    list=function(_,_,_,_,uid) listed_uid=uid;return rows end,
    open=function(_,_,_,entry,current)
        if (entry==next_entry or entry==full_entry) and current() and can_open then return {
            path=entry==next_entry and '/tmp/x/native-reader-v1/next.epub' or '/tmp/x/native-reader-v1/full.epub',
            book_version=1,source_sha256=entry.source_sha256,missing_images=entry.missing_images} end
    end,
} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(document) return document.identity or {} end} end
local shown
package.preload['weread.ui.end_of_book_dialog']=function() return {show=function(opts,callbacks) shown={opts=opts,callbacks=callbacks} end} end
local search_entry
local refresh_entry
local position_entry
local manual_entry
package.preload['weread.lib.native_direct_pending']=function() return {read=function(_,_,_,entry,current)
    if current() then return {file_id=entry.file_id,xpointer='saved'} end end} end
package.preload['weread.ui.native_direct_reconnect']=function() return {open_manual=function(_,entry,record)
    manual_entry={entry=entry,record=record};return true end} end
package.preload['weread.ui.native_direct_position']=function() return {start=function(_,entry,options)
    position_entry={entry=entry,options=options};return true end} end
package.preload['weread.ui.native_direct_image_refresh']=function() return {start=function(_,entry) refresh_entry=entry end} end
package.preload['weread.ui.native_direct_search']=function() return {open=function(_,entry) search_entry=entry;return true end} end
local online_search
package.preload['weread.ui.book_search']=function() return {open=function(_,id,chapters,uid,entry)
    online_search={id=id,chapters=chapters,uid=uid,entry=entry};return true end} end
local auto_target
package.preload['weread.ui.native_direct_reading']=function() return {start=function(_,book,view,options)
    auto_target={book=book,view=view,options=options};return true end} end
local progress_options
package.preload['weread.ui.reader_progress']=function() return {show=function(_,options) progress_options=options end} end
local catalog=require('weread.lib.native_direct_catalog_store')
local weights,reads
catalog.read=function() error('navigation read the complete catalog') end
catalog.read_weights=function(_,_,_,_,entry,current)
    assert(in_worker and entry==source and current(),'estimate left the chapter worker or the reader session')
    reads=reads+1
    return weights
end
local Nav=require('weread.ui.native_direct_navigation')
local function fixture()
    shown=nil;auto_target=nil;refresh_entry=nil;position_entry=nil;manual_entry=nil;rows={next_entry};source_ok=true;can_open=true;page=1
    progress_options=nil;scheduled={};reads=0;weights={before=100,chapter=200,total=1000}
    local s={jobs={},opened=0,online=false,account='owner',scope={vid='123',epoch=1}}
    local document={file='/tmp/x/native-reader-v1/current.epub',identity={book_id='42',file_id=source.file_id,book_version=1}}
    local host={ui={document=document},client={},_reader_session_gen=1,
        settings={data_dir='/tmp/x',get_auth_scope=function() return s.scope end,
            auth_scope_matches=function(_,value) return s.scope==value end,
            get_book=function(_,id) return {book_id=id,title='Book'} end},
        library_db={accountKey=function() return s.account end},isNetworkConnected=function() return s.online end,
        showBusy=function(self,_,cancel) self.busy_message={};s.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,message) s.message=message end,
        showList=function(_,title,items,_,options)
            s.title=title;s.items=items;s.subtitle=options.subtitle
            s.select=function(index) options.on_choice(items[index]) end
            return {}
        end,
        showBookMenu=function(self) self._book_detail_view={} end,
        showMyCloudMarks=function(_,id) s.notes={'marks',id} end,
        showMyCloudBookmarks=function(_,id) s.notes={'bookmarks',id} end,
        showMyCloudThoughts=function(_,id) s.notes={'thoughts',id} end,
        openFile=function(_,file) s.opened=s.opened+1;s.path=file end,
        _native_direct_navigation_worker={start=function(_,task,callback) s.jobs[#s.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() s.cancelled=true end}}
    function s.finish(index) local job=s.jobs[index];in_worker=true;local value=job.task();in_worker=false;job.callback(value) end
    return host,s
end
local host,s=fixture();expect(Nav.start(host),'navigation did not start');s.finish(1)
expect(shown and shown.opts.show_previous_chapter and shown.opts.show_next_chapter and not shown.opts.show_sync_row,
    'native quick menu did not show chapter navigation or hid sync')
shown.callbacks.on_next();s.finish(2)
expect(s.opened==1 and s.path:find('/native%-reader%-v1/next.epub') and listed_uid=='38',
    'adjacent saved chapter not found through its targeted lookup')
expect(reads==0,'quick menu and adjacent navigation read catalog weights')
host,s=fixture();Nav.start(host);s.finish(1)
shown.callbacks.on_reader_progress();shown.callbacks.on_reader_progress()
expect(not progress_options and #s.jobs==2 and not host.busy_message,'reading progress skipped or repeated deferred lookup')
s.finish(2);scheduled[1]()
expect(reads==1 and progress_options.chapter_number==2 and progress_options.chapter_count==3
    and progress_options.estimate(50)==20 and not host.busy_message,'verified progress estimate did not open without an extra notice')
host,s=fixture();weights=nil;Nav.start(host);s.finish(1)
shown.callbacks.on_reader_progress();scheduled[1]()
expect(host.busy_message,'slow storage did not offer cancellation')
s.finish(2)
expect(progress_options and not progress_options.estimate(50) and not host.busy_message
    and type(progress_options.next_action)=='function','missing weights blocked chapter progress')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_reader_progress();scheduled[1]()
local loading=s.jobs[2];in_worker=true;local loaded=loading.task();in_worker=false
s.cancel();loading.callback(loaded)
expect(not progress_options and not host.busy_message and s.cancelled,'cancelled weights lookup reopened the panel')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_reader_progress()
host._weread_suspended=true;scheduled[1]();s.jobs[2].callback({weights=weights})
expect(not progress_options and not host._native_direct_navigation and not host.busy_message,
    'suspended reader opened a delayed notice or progress panel')
host,s=fixture();Nav.start(host);s.finish(1)
host._native_direct_navigation_worker.start=function() return false end
shown.callbacks.on_reader_progress();scheduled[1]()
expect(progress_options and not progress_options.estimate(50) and not host.busy_message,
    'unable to start an optional worker blocked chapter progress')
host,s=fixture();Nav.start(host);s.finish(1)
shown.callbacks.on_book_details()
expect(host._book_detail_view and not host._native_direct_navigation and not auto_target,
    'explicit book details did not open over the reader')
host,s=fixture();Nav.start(host);s.finish(1)
shown.callbacks.on_download_chapters()
expect(auto_target and auto_target.book.book_id==source.book_id and auto_target.view==host.ui
    and auto_target.options.from_reader and auto_target.options.batch and auto_target.options.anchor==source
    and not host._native_direct_navigation,'download did not use the current verified reader chapter')
host,s=fixture();Nav.start(host);s.finish(1);host._reader_session_gen=2
shown.callbacks.on_download_chapters()
expect(not auto_target,'stale reader quick menu started a chapter download')
host,s=fixture();Nav.start(host);s.finish(1)
expect(not shown.callbacks.on_native_refresh_images,'complete chapter offered image retry')
source.missing_images=2;host,s=fixture();Nav.start(host);s.finish(1)
expect(type(shown.callbacks.on_native_refresh_images)=='function','missing image retry was not offered')
shown.callbacks.on_native_refresh_images();expect(refresh_entry==source and not host._native_direct_navigation,'image retry lost its chapter')
source.missing_images=0
host,s=fixture();Nav.start(host);s.finish(1);rows={next_entry,full_entry};shown.callbacks.on_next();s.finish(2)
expect(s.opened==0 and s.title=='Choose a saved chapter copy' and #s.items==2,'multiple copies were silently opened')
expect(s.items[1].text:find('2 images unavailable',1,true) and s.items[2].text:find('No missing images',1,true),
    'copy image completeness was not shown')
s.select(2);s.finish(3)
expect(s.opened==1 and s.path:find('/full.epub',1,true),'selected complete copy did not open')
host,s=fixture();Nav.start(host);s.finish(1);rows={next_entry,full_entry};shown.callbacks.on_next();s.finish(2)
local old_select=s.select;s.account='other';old_select(1)
expect(s.opened==0 and #s.jobs==2,'stale account opened a selected copy')
host,s=fixture();Nav.start(host);s.finish(1);rows={next_entry,full_entry};shown.callbacks.on_next();s.finish(2)
local chooser=host._native_direct_navigation.menu
s.select(1);can_open=false;s.finish(3)
expect(s.opened==0 and s.message:find('could not be verified',1,true) and not host.busy_message
    and host._native_direct_navigation.menu==chooser,'damaged selected copy closed the chooser')
can_open=true;s.select(2);s.select(1)
expect(#s.jobs==4,'repeated choice replaced the in-flight check')
local stopped_job=s.jobs[4];local stopped_result=stopped_job.task();local stop=s.cancel
stop()
expect(s.cancelled and not host.busy_message and host._native_direct_navigation.menu==chooser,
    'cancelling a saved-file check closed the chooser')
s.select(2);stop();stopped_job.callback(stopped_result)
expect(#s.jobs==5 and s.opened==0 and host.busy_message,'cancelled check affected a newer choice')
s.finish(5)
expect(s.opened==1 and s.path:find('/full.epub',1,true),'replacement copy did not open from the chooser')
host,s=fixture();Nav.start(host);s.finish(1);rows={next_entry,full_entry};shown.callbacks.on_next();s.finish(2)
s.select(2);local queued=s.jobs[3];local ready=queued.task();s.account='other';queued.callback(ready)
expect(s.opened==0 and not host._native_direct_navigation,'late selection opened under a different account')
host,s=fixture();Nav.start(host);s.finish(1);rows={next_entry,full_entry};shown.callbacks.on_next();s.finish(2)
s.select(2);source_ok=false;s.finish(3)
expect(s.opened==0 and not host._native_direct_navigation and s.message:find('could not be verified',1,true),
    'changed source retained a stale chooser')
host,s=fixture();Nav.start(host);s.finish(1);rows={next_entry,full_entry};shown.callbacks.on_next();s.finish(2)
local dismissed=s.select;require('ui/uimanager'):close(host._native_direct_navigation.menu);dismissed(1)
expect(s.opened==0 and #s.jobs==2 and not host._native_direct_navigation,'dismissed copy menu remained active')
host,s=fixture();Nav.start(host);s.finish(1)
expect(shown.opts.enable_search_cached,'native quick menu did not enable downloaded search')
shown.callbacks.on_search_cached()
expect(search_entry==source and not host._native_direct_navigation,'downloaded search did not receive the verified chapter')
host,s=fixture();Nav.start(host);s.finish(1)
expect(shown.opts.enable_search_book,'native quick menu did not enable online search')
shown.callbacks.on_search_book()
expect(online_search and online_search.id=='42' and online_search.uid=='37' and online_search.entry==source
    and not host._native_direct_navigation,'online search did not receive the verified chapter')
host,s=fixture();Nav.start(host);s.finish(1)
expect(type(shown.callbacks.on_native_offline_reminder)=='function','offline reminder action missing')
shown.callbacks.on_native_offline_reminder();expect(#s.jobs==2,'offline reminder did not recheck its source')
s.finish(2)
expect(manual_entry and manual_entry.entry==source and manual_entry.record.xpointer=='saved'
    and not host._native_direct_navigation,'offline reminder did not receive the verified chapter')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_native_offline_reminder()
local pending_job=s.jobs[2];local pending_value=pending_job.task();s.account='other';pending_job.callback(pending_value)
expect(not manual_entry and not host._native_direct_navigation,'old account opened the offline reminder')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_native_offline_reminder();source_ok=false;s.finish(2)
expect(not manual_entry and s.message:find('could not be verified',1,true),'changed source opened the offline reminder')
host,s=fixture();Nav.start(host);s.finish(1);rows={};shown.callbacks.on_next();s.finish(2)
expect(s.opened==0 and not s.message and auto_target and auto_target.options.cached
    and auto_target.options.anchor==source and auto_target.options.offline_notice=='Chapter unavailable offline'
    and not auto_target.options.target and not host._native_direct_navigation,
    'offline missing chapter did not offer saved chapters without skipping')
host,s=fixture();s.online=true;Nav.start(host);s.finish(1);rows={};shown.callbacks.on_next();s.finish(2)
expect(auto_target and auto_target.options.target.uid=='38' and auto_target.options.target.from_uid=='37'
    and auto_target.options.target.order==3 and auto_target.options.target.catalog_sha256==source.catalog_sha256,
    'online missing chapter was not tied to verified catalog')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_next();local result=s.jobs[2].task();s.account='other';s.jobs[2].callback(result)
expect(s.opened==0 and not host._native_direct_navigation,'old account opened a chapter')
host,s=fixture();Nav.start(host,1);s.finish(1);rows={};result=s.jobs[2].task();host._weread_suspended=true;s.jobs[2].callback(result)
expect(not auto_target and not host._native_direct_navigation and not host.busy_message,
    'a suspended reader opened a saved chapter list')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_next();source_ok=false;s.finish(2)
expect(s.opened==0 and s.message:find('could not be verified',1,true),'changed source file was accepted')
host,s=fixture();Nav.start(host);s.finish(1);can_open=false;shown.callbacks.on_next();s.finish(2)
expect(s.opened==0 and auto_target and auto_target.options.cached and auto_target.options.failed_copy==next_entry,
    'unverified destination was opened or offered again')
host,s=fixture();s.online=true;Nav.start(host);s.finish(1);can_open=false;shown.callbacks.on_next();s.finish(2)
expect(s.opened==0 and auto_target and auto_target.options.target.uid=='38','online corrupt copy could not be downloaded again')
host,s=fixture();Nav.start(host,1);s.finish(1);expect(#s.jobs==2,'end-of-book did not navigate');s.finish(2)
expect(s.opened==1,'end-of-book did not open adjacent chapter')
source.catalog_order=3;source.catalog_next=nil
host,s=fixture();Nav.start(host);s.finish(1)
expect(shown.opts.enable_next_chapter==false and shown.opts.enable_previous_chapter,'last chapter menu offered Next')
for _,online in ipairs({false,true}) do
    host,s=fixture();s.online=online;Nav.start(host,1);s.finish(1)
    expect(s.message=='You have reached the last chapter.' and #s.jobs==1 and s.opened==0 and not auto_target,
        'last chapter attempted another lookup or download')
end
source.catalog_order=1;source.catalog_prev=nil;source.catalog_next='38'
host,s=fixture();Nav.start(host);s.finish(1)
expect(shown.opts.enable_previous_chapter==false and shown.opts.enable_next_chapter,'first chapter menu offered Previous')
host,s=fixture();Nav.start(host,-1);s.finish(1)
expect(s.message=='You have reached the first chapter.' and #s.jobs==1 and s.opened==0,'first chapter attempted another lookup')
source.catalog_order=2;source.catalog_prev='36'
local sha=source.catalog_sha256;source.catalog_sha256=nil
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_next()
expect(s.opened==0 and auto_target and auto_target.options.cached and auto_target.options.anchor==source
    and auto_target.options.offline_notice=='Chapter order is unavailable offline',
    'offline chapter without a known order did not offer saved chapters')
host,s=fixture();s.online=true;Nav.start(host);s.finish(1);shown.callbacks.on_next()
expect(s.opened==0 and s.message=='Chapter order is unavailable. Reopen this chapter online to update it.',
    'unverified chapter order did not explain how to recover')
source.catalog_sha256=sha
for _,variant in ipairs({'marks','bookmarks','thoughts'}) do
    host,s=fixture();expect(Nav.open_notes(host,variant),'direct notes did not start');s.finish(1)
    expect(s.notes and s.notes[1]==variant and s.notes[2]=='42' and not host._native_direct_navigation and s.opened==0,
        'direct notes did not use the verified book')
end
host=fixture();expect(not Nav.open_notes(host,'unexpected'),'unsupported notes entry accepted')
host,s=fixture();s.account=nil;expect(Nav.open_notes(host,'marks') and #s.jobs==0
    and s.message=='Sign in to the account that saved these E-Ink chapters.','missing account started a note lookup')
host,s=fixture();expect(Nav.open_notes(host,'marks'));local pending=s.jobs[1];local note_result=pending.task()
s.account='other';pending.callback(note_result);expect(not s.notes and not host._native_direct_navigation,'stale account opened notes')
host,s=fixture();expect(Nav.open_notes(host,'bookmarks'));source_ok=false;s.finish(1)
expect(not s.notes and s.message:find('could not be verified',1,true),'unverified direct file opened notes')
host,s=fixture();expect(Nav.open_notes(host,'thoughts'));host.ui.document.identity.file_id=string.rep('0',64);s.finish(1)
expect(not s.notes and s.message:find('could not be verified',1,true),'open document and saved file mismatch opened notes')
for _,action in ipairs({'cloud','upload'}) do
    host,s=fixture();expect(Nav.open_position(host,action));s.finish(1)
    expect(position_entry and position_entry.entry==source and position_entry.options[action]==true
        and not host._native_direct_navigation,'position action did not use the verified chapter')
    host,s=fixture();expect(Nav.open_position(host,action));local job=s.jobs[1];local pending_result=job.task();s.account='other';job.callback(pending_result)
    expect(not position_entry and not host._native_direct_navigation,'stale account started a position action')
    host,s=fixture();expect(Nav.open_position(host,action));job=s.jobs[1];pending_result=job.task();page=2;job.callback(pending_result)
    expect(not position_entry and not host._native_direct_navigation,'changed page started a position action')
end
host,s=fixture();expect(Nav.open_position(host,'cloud'));host.ui.document.identity.file_id=string.rep('0',64);s.finish(1)
expect(not position_entry and s.message:find('could not be verified',1,true),'unverified file started a position action')
expect(not Nav.open_position(host,'unexpected'),'unsupported position action accepted')
print('PASS: local native reader navigation, account guards and online fallback ('..checks..' checks)')
