package.path='./?.lua;'..package.path
local UI={}
function UI:show(value) self.top=value end
function UI:close(value) if value.onCloseWidget then value:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local scope_valid=true
package.preload['weread.ui.page_scope']=function() return {capture=function() return function() return scope_valid end end} end
local catalog_available=false
package.preload['weread.lib.content']=function() return {load_catalog_cache=function() return catalog_available and {{chapterUid='1'}} or nil end} end
local identity=string.rep('a',64);local raw_hash=string.rep('b',64)
local cached_valid=true
local valid_path
package.preload['weread.lib.cached_book_search']=function() return {snapshot=function(path)
    if not cached_valid or valid_path and valid_path~=path then return nil end
    return {identity={file_id=identity},record={raw_sha256=raw_hash,format='web_xhtml'}}
end} end
local Source=require('weread.lib.position_source')
local original_metadata=Source.document_metadata
local document_valid=true
Source.document_metadata=function()
    if not document_valid then return nil end
    return {identity={file_id=identity},record={raw_sha256=raw_hash,format='web_xhtml'}}
end
local worker
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local instance={}
    function instance:start(task,callback) self.task,self.callback=task,callback;worker=self;return true end
    function instance:cancel() self.cancelled=true end
    function instance:complete() self.callback(self.task()) end
    return instance
end} end
local Hint=require('weread.lib.unindexed_resume')
local M=require('weread.ui.unindexed_resume')
local owner=string.rep('c',20);local account=owner;local epoch=4;local auth={vid='41',epoch=4}
local point={book_id='41',chapter_uid='2',file_id=identity,raw_sha256=raw_hash,
    basis='filtered_xhtml_utf16',upload_verified=false}
local hint=assert(Hint.make(point,'41',owner,epoch))
local book={book_id='41',cached_chapters={['2']='/chapter.epub'},unindexed_resume=hint}
local host={settings={},library_db={},ui={},_reader_session_gen=0,client={}}
function host.settings:get(key,default) if key=='auth_epoch' then return epoch end;return default end
function host.settings:get_book() return book end
function host.settings:get_auth_scope() return auth end
function host.settings:auth_scope_matches(value) return value==auth end
function host.library_db:accountKey() return account end
function host.library_db:getChapters() return nil end
function host:showBusy(_message,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showInfo(message) self.info=message end
function host:openFile(path,callback) self.opened=path;self.receive=callback end
function host:openBookForReading(_book,_quiet,options) self.fallback=options;return true end
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
expect(M.start(host,book,hint,{'/chapter.epub'}),'verification did not start')
expect(host.busy_message and not host.opened,'opening was not deferred')
worker:complete()
expect(host.opened=='/chapter.epub' and host.receive and not host.busy_message,'verified chapter did not open')
local frame={local_only=true};local next_host={ui={document={file='/chapter.epub'}},settings=host.settings,
    library_db=host.library_db,progress_sync={navigation_generation=0},detectWeReadBook=function() return '41' end,
    showInfo=host.showInfo}
next_host.progress_sync.begin_file_resume=function(_self,options) assert(options.allow_missing_catalog);return frame end
next_host.progress_sync.finish_file_resume=function(_self,value,applied) return value==frame and not applied end
expect(host.receive{weread=next_host,document=next_host.ui.document}==true,'new reader did not retain the local-only sync gate')
expect(host.receive{weread=next_host,document=next_host.ui.document}==false,'reader handoff was reusable')
host.opened=nil
expect(M.start(host,book,hint,{'/chapter.epub'}),'changed-session verification did not start')
local changing=worker;epoch=5;changing:complete();epoch=4
expect(not host.opened and not host._unindexed_resume_job,'changed login epoch retained stale work')
expect(M.start(host,book,hint,{'/chapter.epub'}),'changed-hint verification did not start')
changing=worker;book.unindexed_resume.raw_sha256=string.rep('f',64);changing:complete()
book.unindexed_resume.raw_sha256=raw_hash
expect(not host.opened and not host._unindexed_resume_job,'a changed stored chapter accepted a stale result')
expect(M.start(host,book,hint,{'/chapter.epub'}),'post-open recheck did not start');worker:complete()
document_valid=false
expect(host.receive{weread=next_host,document=next_host.ui.document}==false and next_host.info~=nil,
    'the newly opened document skipped source metadata rechecking')
document_valid=true;host.opened=nil
expect(M.start(host,book,hint,{'/chapter.epub'}),'changed-account verification did not start')
local old=worker;account=string.rep('d',20);old:complete();account=owner
expect(not host.opened and not host._unindexed_resume_job,'account change retained stale work')
expect(M.start(host,book,hint,{'/chapter.epub'}),'cancelled verification did not start')
old=worker;host.busy_message.cancel();old:complete()
expect(old.cancelled and not host.opened and not host._unindexed_resume_job,'cancelled work opened a file')
expect(M.start(host,book,hint,{'/chapter.epub'}),'changed-catalog verification did not start')
catalog_available=true;worker:complete();catalog_available=false
expect(not host.opened and not host._unindexed_resume_job,'a restored catalog accepted a stale selection')
expect(M.start(host,book,hint,{'/chapter.epub'}),'changed-source verification did not start')
cached_valid=false;worker:complete();cached_valid=true
expect(UI.top and UI.top.ok_callback and not host.opened,'changed source did not ask before using the old position')
UI.top.ok_callback()
expect(host.fallback and host.fallback.skip_unindexed_resume and host.fallback.prefer_exact,
    'confirmed fallback did not preserve the old reading rules')
host.fallback=nil;scope_valid=true
expect(M.start(host,book,hint,{'/chapter.epub'}),'stale fallback verification did not start')
cached_valid=false;worker:complete();cached_valid=true
local old_dialog=UI.top;scope_valid=false;old_dialog.ok_callback();scope_valid=true
expect(not host.fallback,'stale confirmation opened a file');M.cancel(host)
scope_valid=true;host.opened=nil;valid_path='/full.epub'
function host:getFullBookCachePath() return '/full.epub' end
expect(M.start(host,book,hint,{'/chapter.epub','/full.epub'}),'multiple-cache verification did not start')
worker:complete()
expect(host.opened=='/full.epub','matching full-book identity was hidden by a different chapter cache')
M.cancel(host);valid_path=nil
-- A cloud view is scoped to imported books, and remains usable with a catalog.
local imported='CB_SyntheticResume'
local imported_point={book_id=imported,chapter_uid='2',file_id=identity,raw_sha256=raw_hash,
    basis='filtered_xhtml_utf16',upload_verified=false}
local cloud_hint=assert(Hint.make(imported_point,imported,owner,epoch))
book={book_id=imported,cached_chapters={['2']='/chapter.epub'},cb_cloud_view_resume=cloud_hint}
host.opened=nil;catalog_available=true
expect(M.start(host,book,cloud_hint,{'/chapter.epub'},{cloud_view=true}),'cloud view verification did not start')
worker:complete()
expect(host.opened=='/chapter.epub','catalog blocked the verified cloud view')
host.opened=nil
expect(M.start(host,book,cloud_hint,{'/chapter.epub'},{cloud_view=true}),'changed cloud hint verification did not start')
old=worker;book.cb_cloud_view_resume.raw_sha256=string.rep('f',64);old:complete()
book.cb_cloud_view_resume.raw_sha256=raw_hash
expect(not host.opened and not host._unindexed_resume_job,'changed cloud hint retained stale work')
expect(M.start(host,book,cloud_hint,{'/chapter.epub'},{cloud_view=true}),'changed cloud account verification did not start')
old=worker;account=string.rep('d',20);old:complete();account=owner
expect(not host.opened and not host._unindexed_resume_job,'foreign account opened cloud view')
expect(M.start(host,book,cloud_hint,{'/chapter.epub'},{cloud_view=true}),'changed cloud file verification did not start')
cached_valid=false;worker:complete();cached_valid=true
expect(UI.top and UI.top.ok_callback and not host.opened,'changed cloud file skipped fallback confirmation')
M.cancel(host);catalog_available=false
Source.document_metadata=original_metadata
print(('unindexed_resume_ui_spec: %d checks'):format(checks))
