package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local scheduled={};local shown
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,task) scheduled[#scheduled+1]=task end,
    unschedule=function() end,show=function(_,widget) shown=widget end,close=function() end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,opts) return opts end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
local in_worker=false;local page=1;local scope={vid='123',epoch=1};local account='owner';local current=true
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,source_sha256=string.rep('c',64),file_id=string.rep('a',64)}
local wanted={book_id='42',chapter_uid='38',chapter_idx=3,chapter_offset=222,stamp=string.rep('d',64)}
local target_entry={book_id='42',chapter_uid='38',chapter_idx=3,book_version=7,file_id=string.rep('b',64)}
local identity={book_id='42',book_version=7,file_id=entry.file_id};local native={scope=scope};local web={web={cookies={wr_vid='123'}}}
package.preload['weread.lib.source_context']=function() return {
    location=function() assert(not in_worker,'child accessed native document');return {xpointer='xp'..page,page=page,pos=0,view_mode='page'} end,
    same_location=function(a,b) return a and b and a.xpointer==b.xpointer end,
    capture=function(doc,book,_,options)
        assert(not in_worker and options.is_current())
        local meta=assert(options.metadata_resolver(doc,book,'OEBPS/text/chapter.xhtml'))
        return {file=doc.file,book_id=book,chapter_uid=meta.chapter_uid,identity=meta.identity,
            render_path='OEBPS/text/chapter.xhtml',text='sample',point_offset=1}
    end,
} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function()
    assert(not in_worker,'child read native document identity');return identity end} end
package.preload['weread.lib.native_direct_cache']=function() return {valid_entry=function(v,id,owner)
    return (v==entry or v==target_entry) and id=='42' and owner=='123' end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,path) return path=='/target' end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return native end,matches=function() return current end} end
package.preload['weread.lib.source_currentness']=function() return {capture=function() return web end,matches=function() return current end} end
local web_renewals,native_renewals=0,0
package.preload['weread.lib.native_read_recovery']=function() return {cancel=function() end,start=function(_,job,selected,opts)
    if job.recovery_attempted then return false end
    job.recovery_attempted=true;native_renewals=native_renewals+1;opts.complete(true,selected);return true
end} end
local why
local cloud_relation='different';local cloud_error;local cloud_offset=200;local cloud_stamp=string.rep('e',64);local target_error
local upload_offset,upload_pending,upload_started,upload_accepted,upload_cancelled,review_archived
local upload_callback,upload_guard,review_pending
package.preload['weread.lib.native_direct_position']=function() return {prepare=function(_,_,e,file,context,n,w,active)
    assert(in_worker and e==entry and file==context.file and n==native and w==web and active())
    if why then return nil,why end
    return {book_id=e.book_id,chapter_uid=e.chapter_uid,chapter_idx=e.chapter_idx,chapter_offset=123,
        file_id=e.file_id,book_version=e.book_version,raw_sha256=e.source_sha256,basis='filtered_xhtml_utf16',
        source_current=true,upload_verified=false}
end} end
package.preload['weread.lib.native_direct_upload_preview']=function() return {prepare=function(_,_,e,file,context,n,w,active)
    assert(in_worker and e==entry and file==context.file and n==native and w==web and active())
    if why then return nil,why end
    local point={book_id=e.book_id,chapter_uid=e.chapter_uid,chapter_idx=e.chapter_idx,chapter_offset=123,
        file_id=e.file_id,book_version=e.book_version,raw_sha256=e.source_sha256,basis='filtered_xhtml_utf16',
        source_current=true,upload_verified=false}
    return {position=point,before={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=upload_offset,
        raw_percent=10,summary='previous summary'},desired={book_id='42',chapter_uid='37',chapter_idx=2,
        chapter_offset=123,raw_percent=10,summary='new summary'},counts={readingTime=1,recordReadingTime=2,ttsTime=0},
        version=7,shelf_sha256=string.rep('d',64),source_sha256=e.source_sha256,file_id=e.file_id,
        basis='filtered_xhtml_utf16',dispatch_authorized=false}
end} end
package.preload['weread.lib.native_position_service']=function() return {new=function() return {
    pending=function() return upload_pending end,cancel=function() upload_cancelled=true end,
    start=function(_,metadata,guard,callback)
        assert(not in_worker and guard() and metadata.desired.chapter_offset==123)
        upload_started=upload_started+1;upload_callback,upload_guard=callback,guard;return true
    end,accept=function(_,token) assert(token=='valid');upload_accepted=true;return true end,
} end} end
package.preload['weread.lib.native_position_review']=function() return {new=function() return {
    cancel=function() end,current=function(_,token) return token=='review' end,
    start=function(_,guard,callback,pending)
        assert(not in_worker and guard() and pending==review_pending);callback({kind='observed',percent=10},'review');return true
    end,archive=function(_,token) assert(token=='review');review_archived=true;return true end,
} end} end
package.preload['weread.lib.native_direct_cloud']=function() return {valid_target=function(v)
    return type(v)=='table' and v.book_id=='42' and type(v.stamp)=='string' end,
    same_target=function(a,b)
        return a and b and a.book_id==b.book_id and a.chapter_uid==b.chapter_uid and a.chapter_idx==b.chapter_idx
            and a.chapter_offset==b.chapter_offset and a.stamp==b.stamp
    end,prepare=function(_,_,e,file,context,n,w,active)
    assert(in_worker and e==entry and file==context.file and n==native and w==web and active())
    if cloud_error then return nil,cloud_error end
    local point={book_id=e.book_id,chapter_uid=e.chapter_uid,chapter_idx=e.chapter_idx,chapter_offset=123,
        file_id=e.file_id,book_version=e.book_version,raw_sha256=e.source_sha256,basis='filtered_xhtml_utf16',
        source_current=true,upload_verified=false}
    local result={position=point,relation=cloud_relation}
    if cloud_relation=='other_chapter' then result.target=wanted end
    if cloud_relation=='different' then result.cloud_offset=cloud_offset
        result.target={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=cloud_offset,stamp=cloud_stamp}
        result.anchor={co=cloud_offset,
        text='unique sample anchor for navigation',point_offset=2,point_unit='unicode_scalars',basis='filtered_xhtml_utf16'} end
    return result
end} end
package.preload['weread.lib.native_direct_cloud_target']=function() return {resolve=function(_,_,e,file,context,n,w,active,target,book)
    assert(in_worker and e==entry and file==context.file and n==native and w==web and active() and target==wanted and book.book_id=='42')
    if target_error then return nil,target_error end
    return {path='/target',entry=target_entry,target=wanted,reused=true}
end} end
package.preload['weread.lib.native_direct_cloud_handoff']=function() return {prepare=function(host,ctx,resolved,callback)
    assert(not in_worker and host._native_direct_position==ctx and ctx.is_current() and resolved.entry==target_entry and callback)
    return function() return true end
end} end
package.preload['weread.lib.source_dom']=function() return {open_direct_prepared=function(doc,book,uid,id,options)
    assert(not in_worker and doc and book=='42' and uid=='37' and id==identity and options.is_current())
    return {locate_anchor=function(_,anchor) return {co=anchor.co,book_id=book,chapter_uid=uid,file_id=id.file_id,
        render_path='OEBPS/text/chapter.xhtml',xpointer='/cloud'} end}
end} end
package.preload['weread.lib.reader_position']=function() return {
    goto_xpointer=function(_,xp) assert(xp=='/cloud');page=2;return true end,
    snapshot=function() return {} end,contains_anchor=function(_,_,xp) return xp=='/cloud' end,
} end
local Position=require('weread.ui.native_direct_position')
local function fixture()
    scheduled={};shown=nil;page=1;current=true;why=nil;account='owner';cloud_relation='different';cloud_error=nil;cloud_offset=200
    cloud_stamp=string.rep('e',64);target_error=nil;upload_offset=200;upload_pending=nil;upload_started=0
    upload_accepted=false;upload_cancelled=false;review_archived=false;upload_callback=nil;upload_guard=nil
    local s={jobs={},infos=0};local doc={file='/tmp/weread/native-reader-v1/file.epub'}
    local host={ui={document=doc,view={view_mode='page'}},_reader_session_gen=1,client={},
        settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,sco) return sco==scope and current end},
        library_db={accountKey=function() return account end,open=function() end},isNetworkConnected=function() return true end,
        showBusy=function(self,_,cancel) self.busy_message={};s.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,message) s.infos=s.infos+1;s.message=message end,
        openFile=function(_,path,callback) s.opened=path;s.handoff=callback end,
        showOffline=function() error('unexpected offline') end,
        source_recovery={start=function(_,_,old,valid,callback)
            web_renewals=web_renewals+1;assert(old==web and valid());callback(web);return true,{} end,cancel=function() end},
        _native_direct_position_worker={start=function(_,task,callback) s.jobs[#s.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() s.cancelled=true end}}
    function s.capture() local task=table.remove(scheduled,1);assert(task);task() end
    function s.result(index)
        in_worker=true;local result=s.jobs[index].task();in_worker=false;s.jobs[index].callback(result)
    end
    return host,s
end
local host,s=fixture();expect(Position.start(host,entry),'position action did not start');s.capture();s.result(1)
expect(s.message=='The local reading position was checked against the chapter source.'
    and not host._native_direct_position,'read-only success not reported')
host,s=fixture();Position.start(host,entry);s.capture();in_worker=true;local stale=s.jobs[1].task();in_worker=false;page=2;s.jobs[1].callback(stale)
expect(s.infos==0 and not host._native_direct_position,'changed viewport accepted stale source point')
host,s=fixture();Position.start(host,entry);s.capture();in_worker=true;stale=s.jobs[1].task();in_worker=false;account='other';s.jobs[1].callback(stale)
expect(s.infos==0 and not host._native_direct_position,'changed account accepted stale source point')
host,s=fixture();Position.start(host,entry);s.capture();why='source_changed';s.result(1)
expect(s.message=='The chapter source changed, so the reading position could not be checked.','source mismatch not explained')
host,s=fixture();Position.start(host,entry);s.capture();why='web_expired';s.result(1)
expect(web_renewals==1 and #s.jobs==2,'definite web expiry did not renew once')
why=nil;s.result(2);expect(s.infos==1 and not host._native_direct_position,'web renewal did not complete')
host,s=fixture();Position.start(host,entry);s.capture();why='auth_expired';s.result(1)
expect(native_renewals==1 and #s.jobs==2,'definite native expiry did not renew once')
why=nil;s.result(2);expect(s.infos==1 and not host._native_direct_position,'native renewal did not complete')
host,s=fixture();Position.start(host,entry);s.capture();local job=s.jobs[1];in_worker=true;local result=job.task();in_worker=false;Position.cancel(host);job.callback(result)
expect(s.infos==0 and not host._native_direct_position,'cancelled check delivered a result')
host,s=fixture();Position.start(host,entry);s.capture();page=2;Position.on_view_changed(host)
expect(s.cancelled and not host._native_direct_position,'moving the page did not cancel in-flight reads')
host,s=fixture();expect(Position.start(host,entry,{cloud=true}),'cloud action did not start');s.capture();s.result(1)
expect(shown and shown.ok_callback and shown.cancel_callback and page==1,'different cloud point skipped confirmation')
shown.ok_callback();s.capture();expect(#s.jobs==2,'cloud target was not rechecked before navigation');s.result(2)
expect(page==2 and s.message=='Opened the cloud reading position in this chapter.' and not host._native_direct_position,
    'confirmed cloud target was not verified and opened')
host,s=fixture();Position.start(host,entry,{cloud=true});s.capture();s.result(1);shown.cancel_callback()
expect(page==1 and s.infos==0 and not host._native_direct_position,'cancel moved the reader')
host,s=fixture();Position.start(host,entry,{cloud=true});s.capture();s.result(1);page=3;shown.ok_callback()
expect(page==3 and s.infos==0 and not host._native_direct_position,'stale confirmation moved the reader')
host,s=fixture();Position.start(host,entry,{cloud=true});s.capture();s.result(1);shown.ok_callback();s.capture()
cloud_offset=250;s.result(2)
expect(page==1 and s.message=='The cloud position changed during the check. Your current page is kept.',
    'cloud changed after confirmation but the reader moved')
host,s=fixture();Position.start(host,entry,{cloud=true});s.capture();s.result(1);shown.ok_callback();s.capture()
cloud_stamp=string.rep('f',64);s.result(2)
expect(page==1 and s.message=='The cloud position changed during the check. Your current page is kept.',
    'changed cloud snapshot at the same offset was accepted')
host,s=fixture();cloud_relation='other_chapter';Position.start(host,entry,{cloud=true});s.capture();s.result(1)
expect(shown and shown.ok_callback and page==1,'another chapter did not request confirmation')
shown.ok_callback();s.result(2)
expect(s.opened=='/target' and type(s.handoff)=='function' and page==1 and not host._native_direct_position,
    'verified cloud chapter was not handed off')
host,s=fixture();cloud_relation='other_chapter';Position.start(host,entry,{cloud=true});s.capture();s.result(1)
shown.ok_callback();target_error='not_entitled';s.result(2)
expect(not s.opened and s.message=='The cloud chapter is not available to this account.' and page==1,
    'unavailable chapter was opened')
host,s=fixture();cloud_relation='same';Position.start(host,entry,{cloud=true});s.capture();s.result(1)
expect(s.message=='The current page matches the cloud reading position.' and page==1,'matching cloud position was not reported')
host,s=fixture();cloud_offset=123;Position.start(host,entry,{cloud=true});s.capture();s.result(1)
expect(s.infos==1 and shown==nil and page==1,'inconsistent worker comparison was accepted')
host,s=fixture();cloud_error='cloud_changed';Position.start(host,entry,{cloud=true});s.capture();s.result(1)
expect(s.message=='The cloud position changed during the check. Your current page is kept.' and page==1,
    'changed remote state did not stop navigation')
host,s=fixture();expect(Position.start(host,entry,{upload=true}),'upload action did not start');s.capture();s.result(1)
expect(shown and shown.ok_callback and upload_started==0,'upload skipped confirmation')
shown.ok_callback();expect(#s.jobs==2 and upload_started==0,'upload skipped fresh proof');s.result(2)
expect(upload_started==1 and upload_guard(),'verified upload was not dispatched')
upload_callback({kind='confirmed',attempted=true},'valid')
expect(upload_accepted and s.message=='Cloud reading position synced and checked.' and not host._native_direct_position,
    'confirmed receipt was not accepted')
host,s=fixture();Position.start(host,entry,{upload=true});s.capture();s.result(1);shown.cancel_callback()
expect(upload_started==0 and upload_cancelled and not host._native_direct_position,'cancel dispatched upload')
host,s=fixture();Position.start(host,entry,{upload=true});s.capture();s.result(1);shown.ok_callback();upload_offset=201;s.result(2)
expect(upload_started==0 and s.message=='The cloud position changed during the check. Your current page is kept.',
    'changed cloud baseline was uploaded')
host,s=fixture();Position.start(host,entry,{upload=true});s.capture();s.result(1);page=2;shown.ok_callback()
expect(upload_started==0 and not host._native_direct_position,'changed page dispatched upload')
host,s=fixture();Position.start(host,entry,{upload=true});s.capture();s.result(1);shown.ok_callback();s.result(2)
upload_callback({kind='unconfirmed',attempted=true},nil)
expect(not upload_accepted and s.message=='The sync result could not be confirmed. Choose sync again to review it.',
    'unconfirmed write was reported successful')
host,s=fixture();Position.start(host,entry,{upload=true});s.capture();s.result(1);shown.ok_callback();s.result(2)
page=2;Position.on_view_changed(host);upload_callback({kind='confirmed',attempted=true},'valid')
expect(upload_cancelled and not upload_accepted and s.infos==0 and not host._native_direct_position,
    'changed page accepted a late upload receipt')
host,s=fixture();upload_offset=123;Position.start(host,entry,{upload=true});s.capture();s.result(1)
expect(upload_started==0 and s.message=='The current page matches the cloud reading position.','matching position was rewritten')
host,s=fixture();review_pending={phase='pending'};upload_pending=review_pending
Position.start(host,entry,{upload=true});expect(shown and upload_started==0,'pending write skipped review')
shown.ok_callback();expect(shown and shown.ok_callback and not review_archived,'review skipped archival choice')
shown.ok_callback();expect(review_archived and upload_started==0
    and s.message=='Previous result archived. Choose sync again to check the current page.','pending review sent or erased without choice')
host=fixture();review_pending={phase='pending'};upload_pending=review_pending
Position.start(host,entry,{upload=true});shown.cancel_callback()
expect(not review_archived and upload_started==0 and not host._native_direct_position,'cancelled review changed pending record')
print('PASS: native position UI checks live page and never touches document from worker ('..checks..' checks)')
