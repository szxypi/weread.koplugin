package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local fingerprint=string.rep('a',64)
local digest=string.rep('b',64)
local scope={vid='123',epoch=1}
local selected={scope=scope,fingerprint=fingerprint,revision=1,store={},credentials={vid='123'}}
local account_valid=true
package.preload['ui/uimanager']=function() return {close=function(_,widget) if widget.onCloseWidget then widget:onCloseWidget() end end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
package.preload['weread.lib.native_read_access']=function() return {
    capture=function() if account_valid then return selected end end,
    matches=function(_,value) return account_valid and value==selected end,
} end
local renewal_count=0
package.preload['weread.lib.native_read_recovery']=function() return {
    cancel=function() end,
    start=function(_,ctx,old,opts)
        if ctx.recovery_attempted then return false end
        ctx.recovery_attempted=true;renewal_count=renewal_count+1
        opts.complete(true,old);return true
    end,
} end
package.preload['weread.lib.native_authorization']=function() return {new=function() return {cancel=function() end} end} end
local sample={book_id='456',version=7,reading_digest=digest,reading_chapters={
    {chapterUid='1',title='First',chapterIdx=1,downloadable=true},
    {chapterUid='2',title='Locked',chapterIdx=2,downloadable=false},
}}
local catalog_error,build_error
package.preload['weread.lib.native_book_catalog']=function() return {read=function()
    if catalog_error then error(catalog_error,0) end
    return sample
end} end
local expected_book,expected_chapter,expected_args
package.preload['weread.lib.native_direct_reader']=function() return {build=function(_,_,book,chapter,args,options)
    expected_book,expected_chapter,expected_args=book,chapter,args
    expect(options.allow_missing_images and options.is_current(),'missing-image policy or scope incorrect')
    if build_error then return nil,build_error end
    return {path='/tmp/settings/native-reader-v1/account/book/file.epub',book_version=7,
        source_sha256=string.rep('c',64),missing_images=0}
end} end
local UI=require('weread.ui.native_direct_reading')
expect(UI.project(sample,'456')~=nil,'valid catalog rejected')
local function clone() return {book_id='456',version=7,reading_digest=digest,reading_chapters={
    {chapterUid='1',title='One',downloadable=true},{chapterUid='2',title='Two',downloadable=true}}} end
for _,mutate in ipairs({function(v) v.book_id='457' end,function(v) v.reading_digest='bad' end,
    function(v) v.reading_chapters[2].chapterUid='1' end,function(v) v.reading_chapters[1].title='bad\n' end,
    function(v) v.reading_chapters[1].downloadable='yes' end,function(v) v.reading_chapters[1].chapterIdx=-1 end,
    function(v) v.reading_chapters[4]={} end}) do
    local bad=clone();mutate(bad);expect(not UI.project(bad,'456'),'invalid catalog accepted')
end
local function fixture()
    account_valid=true;catalog_error=nil;build_error=nil
    local state={jobs={},opened=0,info=0,view={}}
    local host={_book_detail_view=state.view,discovery_epoch=1,_reader_session_gen=1,ui={},client={},
        settings={data_dir='/tmp/settings',get_auth_scope=function() return scope end,
            auth_scope_matches=function(_,s) return account_valid and s==scope end},
        library_db={accountKey=function() return account_valid and 'owner' or 'other' end},
        isNetworkConnected=function() return true end,
        showBusy=function(self,_,cancel) self.busy_message={};state.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,message) state.info=state.info+1;state.message=message end,
        showOffline=function() error('unexpected offline') end,
        showList=function(_,title,items,_,options) state.title=title;state.items=items;state.subtitle=options.subtitle;return {} end,
        openFile=function(_,path) state.opened=state.opened+1;state.path=path end,
        _native_direct_worker={start=function(_,task,callback) state.jobs[#state.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() state.cancelled=true end}}
    function state.finish(index) local job=state.jobs[index];job.callback(job.task()) end
    return host,state
end
local host,s=fixture()
expect(UI.start(host,{book_id='456',title='Test',author='Author'},s.view),'failed to start')
s.finish(1)
expect(#s.items==2 and s.items[1].select_enabled and not s.items[2].select_enabled,'entitlement not shown')
expect(s.subtitle:find('do not sync',1,true),'local-only warning missing')
s.items[2].callback();expect(#s.jobs==1,'locked chapter opened')
s.items[1].callback();expect(#s.jobs==2,'chapter not scheduled')
s.finish(2)
expect(s.opened==1 and s.path:find('/native-reader-v1/',1,true),'chapter not opened')
expect(expected_book.book_id=='456' and expected_chapter.chapterUid=='1' and expected_args.reading_catalog_sha256==digest
    and expected_args.access_fingerprint==fingerprint,'source identity not bound')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.items[1].callback();local stale=s.jobs[2].task();account_valid=false;s.jobs[2].callback(stale)
expect(s.opened==0 and host._native_direct_reading==nil,'stale account opened chapter')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.items[1].callback();build_error='catalog_changed';s.finish(2)
expect(s.opened==0 and s.message=='The chapter list changed. Please open it again.','catalog change not reported')
host,s=fixture();UI.start(host,{book_id='456'},s.view);catalog_error='native_auth/native_catalog_info/http_401';s.finish(1)
expect(#s.jobs==2 and renewal_count==1,'catalog 401 not renewed once')
catalog_error=nil;s.finish(2);expect(s.items~=nil,'renewal did not reload catalog')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.items[1].callback();build_error='auth_expired';s.finish(2)
expect(#s.jobs==3 and renewal_count==2,'chapter 401 not renewed once')
build_error=nil;s.finish(3);expect(s.opened==1,'renewed chapter did not open')
host,s=fixture();UI.start(host,{book_id='456'},s.view);local old=s.jobs[1];UI.cancel(host);old.callback(old.task())
expect(s.opened==0 and not s.items,'cancelled response changed UI')
print('PASS: native chapter catalog, local-only UI, session checks and renewal ('..checks..' checks)')
