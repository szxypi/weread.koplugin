package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
local source={book_id='42',chapter_uid='37',book_version=1,source_sha256=string.rep('c',64),key=string.rep('a',64),copy=0,
    file_id=string.rep('f',64),catalog_sha256=string.rep('b',64),catalog_order=2,catalog_count=3,catalog_prev='36',catalog_next='38'}
local next_entry={book_id='42',chapter_uid='38',book_version=1,source_sha256=string.rep('d',64),key=string.rep('e',64),copy=0,
    catalog_sha256=source.catalog_sha256,catalog_order=3,catalog_count=3,catalog_prev='37'}
local rows={next_entry};local source_ok=true;local can_open=true
package.preload['weread.lib.native_direct_cache']=function() return {
    valid_entry=function(entry,id,account) return entry==source and id=='42' and account=='123' end,
    identify=function(_,_,_,current) return current() and source_ok and source or nil end,
    list=function() return rows end,
    open=function(_,_,_,entry,current)
        if entry==next_entry and current() and can_open then return {path='/tmp/x/native-reader-v1/next.epub',
            book_version=1,source_sha256=entry.source_sha256,missing_images=0} end
    end,
} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(document) return document.identity or {} end} end
local shown
package.preload['weread.ui.end_of_book_dialog']=function() return {show=function(opts,callbacks) shown={opts=opts,callbacks=callbacks} end} end
local auto_target
package.preload['weread.ui.native_direct_reading']=function() return {start=function(_,book,view,options)
    auto_target={book=book,view=view,options=options};return true end} end
local Nav=require('weread.ui.native_direct_navigation')
local function fixture()
    shown=nil;auto_target=nil;rows={next_entry};source_ok=true;can_open=true
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
        showBookMenu=function(self) self._book_detail_view={} end,
        showMyCloudMarks=function(_,id) s.notes={'marks',id} end,
        showMyCloudBookmarks=function(_,id) s.notes={'bookmarks',id} end,
        showMyCloudThoughts=function(_,id) s.notes={'thoughts',id} end,
        openFile=function(_,file) s.opened=s.opened+1;s.path=file end,
        _native_direct_navigation_worker={start=function(_,task,callback) s.jobs[#s.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() s.cancelled=true end}}
    function s.finish(index) local job=s.jobs[index];job.callback(job.task()) end
    return host,s
end
local host,s=fixture();expect(Nav.start(host),'navigation did not start');s.finish(1)
expect(shown and shown.opts.show_previous_chapter and shown.opts.show_next_chapter and not shown.opts.show_sync_row,
    'native quick menu did not show chapter navigation or hid sync')
shown.callbacks.on_next();s.finish(2)
expect(s.opened==1 and s.path:find('/native%-reader%-v1/next.epub'),'adjacent saved chapter not opened')
host,s=fixture();Nav.start(host);s.finish(1);rows={};shown.callbacks.on_next();s.finish(2)
expect(s.opened==0 and s.message=='The adjacent chapter is not saved. Connect to download it.','offline missing chapter was guessed')
host,s=fixture();s.online=true;Nav.start(host);s.finish(1);rows={};shown.callbacks.on_next();s.finish(2)
expect(auto_target and auto_target.options.target.uid=='38' and auto_target.options.target.from_uid=='37'
    and auto_target.options.target.order==3 and auto_target.options.target.catalog_sha256==source.catalog_sha256,
    'online missing chapter was not tied to verified catalog')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_next();local result=s.jobs[2].task();s.account='other';s.jobs[2].callback(result)
expect(s.opened==0 and not host._native_direct_navigation,'old account opened a chapter')
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_next();source_ok=false;s.finish(2)
expect(s.opened==0 and s.message:find('could not be verified',1,true),'changed source file was accepted')
host,s=fixture();Nav.start(host);s.finish(1);can_open=false;shown.callbacks.on_next();s.finish(2)
expect(s.opened==0 and s.message:find('not saved',1,true),'unverified destination opened')
host,s=fixture();Nav.start(host,1);s.finish(1);expect(#s.jobs==2,'end-of-book did not navigate');s.finish(2)
expect(s.opened==1,'end-of-book did not open adjacent chapter')
local sha=source.catalog_sha256;source.catalog_sha256=nil
host,s=fixture();Nav.start(host);s.finish(1);shown.callbacks.on_next()
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
print('PASS: local native reader navigation, account guards and online fallback ('..checks..' checks)')
