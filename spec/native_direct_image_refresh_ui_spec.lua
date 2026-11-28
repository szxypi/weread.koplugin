package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.crypto']=function() return {sha256_hex=function() return string.rep('a',64) end} end
package.preload['weread.lib.native_position_contract']=function() return {account_key=function() return 'owner' end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,path)
    return type(path)=='string' and path:find('/native-reader-v1/',1,true)~=nil end} end
local scope={vid='123',epoch=1};local selected={scope=scope,fingerprint='fingerprint',revision=1}
local authorized=true
package.preload['weread.lib.native_read_access']=function() return {capture=function() return authorized and selected or nil end,
    matches=function(_,value) return authorized and value==selected end} end
local renewed=0
package.preload['weread.lib.native_read_recovery']=function() return {cancel=function() end,
    start=function(_,ctx,old,options)
        if ctx.recovery_attempted then return false end
        ctx.recovery_attempted=true;renewed=renewed+1;options.complete(true,old);return true
    end} end
package.preload['weread.lib.native_direct_cache']=function() return {valid_entry=function(entry,id,account)
    return type(entry)=='table' and id=='42' and account=='123' end} end
local result
local offered,offer_error
package.preload['weread.ui.native_direct_copy_resume']=function() return {offer=function(_,item,path)
    if offer_error then error('dialog unavailable') end
    offered={entry=item,path=path};return true end} end
package.preload['weread.lib.native_direct_image_refresh']=function() return {run=function(_,_,native,entry,path,book,current)
    expect(native==selected and entry.book_id=='42' and path:find('/native-reader-v1/',1,true)
        and book.book_id=='42' and current(),'refresh task lost its source or account')
    return result
end} end
local Refresh=require('weread.ui.native_direct_image_refresh')
local entry={book_id='42',file_id=string.rep('a',64),book_version=3,source_sha256=string.rep('b',64),
    missing_images=2,catalog_sha256=string.rep('c',64)}
local function fixture()
    authorized=true;result=nil;offered=nil;offer_error=false
    local state={jobs={},online=true,account='owner',scope=scope,opened=0}
    local document={file='/tmp/native-reader-v1/old.epub'}
    local host={ui={document=document},client={},_reader_session_gen=1,
        settings={get_auth_scope=function() return state.scope end,auth_scope_matches=function(_,value) return state.scope==value end,
            get_book=function() return {book_id='42',title='Book',author='Author'} end},
        library_db={accountKey=function() return state.account end},isNetworkConnected=function() return state.online end,
        showBusy=function(self,_,cancel) self.busy_message={};state.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,showInfo=function(_,message) state.message=message end,
        openFile=function() state.opened=state.opened+1 end,
        _native_direct_image_refresh_worker={start=function(_,task,callback) state.jobs[#state.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() state.cancelled=true end}}
    function state.finish(index) local job=state.jobs[index];job.callback(job.task()) end
    return host,state
end
local host,s=fixture();s.online=false
expect(not Refresh.start(host,entry) and s.message=='Connect to retry missing chapter images.' and #s.jobs==0,'offline action started')
host,s=fixture();authorized=false
expect(not Refresh.start(host,entry) and s.message=='E-Ink authorization is required to read these chapters.','missing login accepted')
host,s=fixture();expect(Refresh.start(host,entry),'refresh did not start')
result={kind='improved',path='/tmp/native-reader-v1/new.epub',book_version=3,source_sha256=entry.source_sha256,missing_images=0}
s.finish(1)
expect(s.opened==0 and offered and offered.entry==entry and offered.path==result.path
    and not host._native_direct_image_refresh,'improved copy changed the reader or lost its offer')
host,s=fixture();Refresh.start(host,entry);offer_error=true
result={kind='improved',path='/tmp/native-reader-v1/new.epub',book_version=3,source_sha256=entry.source_sha256,missing_images=0}
s.finish(1);expect(s.message:find('new chapter copy',1,true) and s.opened==0,'unavailable offer did not preserve the manual fallback')
host,s=fixture();Refresh.start(host,entry);result={kind='unchanged'};s.finish(1)
expect(s.opened==0 and s.message:find('No additional images',1,true),'unchanged result was not explained')
host,s=fixture();Refresh.start(host,entry);result={kind='improved',path=host.ui.document.file,book_version=3,
    source_sha256=entry.source_sha256,missing_images=0};s.finish(1)
expect(s.opened==0 and s.message:find('Could not retry',1,true),'original path was accepted as a new copy')
host,s=fixture();Refresh.start(host,entry);result={error='auth_expired'};s.finish(1)
expect(renewed==1 and #s.jobs==2,'authorization did not recover once')
result={error='auth_expired'};s.finish(2)
expect(renewed==1 and s.message=='E-Ink authorization expired. Please authorize again.','authorization retried repeatedly')
host,s=fixture();Refresh.start(host,entry);local old=s.jobs[1];result={kind='unchanged'};local response=old.task()
s.account='other';old.callback(response);expect(not s.message and not host._native_direct_image_refresh,'old account result was displayed')
host,s=fixture();Refresh.start(host,entry);old=s.jobs[1];Refresh.cancel(host);old.callback({kind='unchanged'})
expect(not s.message and s.cancelled and s.opened==0,'cancelled response was displayed')
print('PASS: native image refresh reader scope and authorization recovery ('..checks..' checks)')
