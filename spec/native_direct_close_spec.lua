package.path='./?.lua;'..package.path
local checks=0;local function expect(v,msg) checks=checks+1;assert(v,msg) end
local f;local in_worker=false
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_,_,task) f.scheduled[task]=true end,unschedule=function(_,task) f.scheduled[task]=nil end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
package.preload['weread.lib.source_context']=function() return {
    location=function(doc) assert(not in_worker and not f.closed);return {page=doc.page} end,
    same_location=function(a,b) return a and b and a.page==b.page end,
    capture=function(doc,book,_,opts)
        assert(not in_worker and not f.closed and opts.is_current())
        local meta=opts.metadata_resolver(doc,book,'OEBPS/text/chapter.xhtml');if not meta then return {error='identity'} end
        return {file=doc.file,book_id=book,chapter_uid=meta.chapter_uid,identity=meta.identity,
            render_path='OEBPS/text/chapter.xhtml',text='sample',point_offset=1}
    end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function()
    assert(not in_worker and not f.closed);return f.identity end} end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return f.access end} end
package.preload['weread.lib.source_currentness']=function() return {matches=function() return f.access end} end
package.preload['weread.lib.memory_worker']=function() return {new=function() return {
    start=function(_,task,callback) f.jobs[#f.jobs+1]={task=task,callback=callback};return true end,
    cancel=function() f.worker_cancelled=true end} end} end
package.preload['weread.lib.native_direct_upload_preview']=function() return {prepare=function(_,_,entry,file,input,_,_,current)
    assert(in_worker and f.closed and current() and input.file==file and entry.book_id==input.book_id)
    return f.preview
end} end
package.preload['weread.lib.native_position_service']=function() return {new=function() return {
    pending=function() return f.pending end,cancel=function() f.service_cancelled=true end,
    start=function(_,metadata,guard,callback)
        assert(not in_worker and guard());f.sent=(f.sent or 0)+1;f.guard=guard;f.callback=callback;f.sent_metadata=metadata;return true
    end,accept=function(_,token) f.accepted=token=='receipt';return f.accepted end} end} end
local Close=require('weread.lib.native_direct_close')
local function fixture()
    f={scheduled={},jobs={},enabled=true,online=true,access=true,account='owner',messages={}}
    local scope={vid='123',epoch=1};local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,
        source_sha256=string.rep('c',64),file_id=string.rep('a',64)}
    local before={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=10,raw_percent=20,summary='old summary'}
    local desired={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=11,raw_percent=20,summary='new summary'}
    f.identity={book_id='42',book_version=7,file_id=entry.file_id}
    f.preview={position={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=11,file_id=entry.file_id,
        book_version=7,raw_sha256=entry.source_sha256,basis='filtered_xhtml_utf16',source_current=true,upload_verified=false},
        before=before,desired=desired,counts={readingTime=10,recordReadingTime=0,ttsTime=0},version=7,
        shelf_sha256=string.rep('b',64),source_sha256=entry.source_sha256,file_id=entry.file_id,
        basis='filtered_xhtml_utf16',dispatch_authorized=false}
    local doc={file='/native',page=2};local reader={document=doc,view={view_mode='page'}}
    local host={ui=reader,settings={data_dir='/synthetic',get=function() return {upload_on_close=f.enabled} end,
        auth_scope_matches=function(_,value) return value==scope and f.access end},client={},
        library_db={accountKey=function() return f.account end,open=function() end},
        isNetworkConnected=function() return f.online end,
        showTransientInfo=function(_,message) f.messages[#f.messages+1]=message end}
    local context={entry=entry,reader=reader,document=doc,file=doc.file,scope=scope,account='owner',native={},web={},location={page=1},
        baseline={position=before,counts=f.preview.counts,version=7,shelf_sha256=f.preview.shelf_sha256,
            source_sha256=entry.source_sha256,file_id=entry.file_id}}
    host._native_direct_interval={context=context,access_current=function() return f.access end}
    f.host,f.doc=host,doc
    function f.freeze() return Close.freeze(host) end
    function f.start(token) f.closed=true;host.ui=nil;return Close.start(host,token) end
    function f.launch() local task=next(f.scheduled);assert(task);f.scheduled[task]=nil;task() end
    function f.result(index) local job=f.jobs[index];in_worker=true;local result=job.task();in_worker=false;job.callback(result) end
    return f
end
fixture();local token=f.freeze();expect(token and f.start(token),'verified changed page did not start')
f.launch();f.result(1);expect(#f.jobs==2 and not f.sent,'close did not recheck source and cloud')
f.result(2);expect(f.sent==1 and f.guard(),'close sync did not start')
f.callback({kind='confirmed',attempted=true},'receipt');expect(f.accepted and f.service_cancelled,'confirmed sync not retired')
fixture();f.enabled=false;expect(not f.freeze(),'disabled close sync prepared')
fixture();f.host._native_direct_interval=nil;expect(not f.freeze(),'unverified session prepared a close upload')
fixture();f.doc.page=1;expect(not f.freeze(),'unchanged page prepared')
fixture();f.online=false;expect(not f.freeze(),'offline close prepared')
fixture();f.identity.file_id='changed';expect(not f.freeze(),'changed file prepared')
fixture();f.host._native_direct_interval.attempt={};expect(not f.freeze(),'overlapping timed upload prepared')
fixture();f.host._offline_time_transfer_lock={};expect(not f.freeze(),'close upload ignored active time transfer')
fixture();token=f.freeze();f.pending={phase='pending'};expect(not f.start(token) and #f.messages==1,'pending send was not blocked')
fixture();token=f.freeze();f.start(token);f.launch();f.preview.before.chapter_offset=30;f.result(1)
expect(not f.sent and #f.messages==1,'changed cloud baseline was accepted')
fixture();token=f.freeze();f.start(token);f.launch();f.result(1);f.preview.desired.summary='changed';f.result(2)
expect(not f.sent and #f.messages==1,'changed preflight was accepted')
fixture();token=f.freeze();f.start(token);f.launch();f.preview.position.chapter_offset=10;f.preview.desired.chapter_offset=10
f.result(1);expect(not f.sent and #f.jobs==1 and #f.messages==0,'already synced page sent another request')
fixture();token=f.freeze();f.start(token);f.launch();local late=f.jobs[1];in_worker=true;local stale=late.task();in_worker=false
Close.cancel(f.host);late.callback(stale)
expect(not f.sent and f.worker_cancelled,'late result survived a new reader')
fixture();token=f.freeze();f.start(token);f.launch();f.result(1);f.result(2);f.callback({kind='unconfirmed',attempted=true})
expect(not f.accepted and #f.messages==1 and f.service_cancelled,'unknown receipt was accepted')
fixture();token=f.freeze();f.start(token);f.launch();late=f.jobs[1];in_worker=true;stale=late.task();in_worker=false
f.access=false;late.callback(stale)
expect(not f.sent and f.worker_cancelled,'changed access started a write')
fixture();token=f.freeze();f.start(token);f.launch();late=f.jobs[1];in_worker=true;stale=late.task();in_worker=false
f.enabled=false;late.callback(stale)
expect(not f.sent and f.worker_cancelled,'disabled close sync started a write')
fixture();token=f.freeze();f.start(token);f.launch();late=f.jobs[1];in_worker=true;stale=late.task();in_worker=false
f.account='another owner';late.callback(stale)
expect(not f.sent and f.worker_cancelled,'account change started a write')
print('PASS: native close sync freezes the viewport and guards detached writes ('..checks..' checks)')
