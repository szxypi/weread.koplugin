package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local scheduled={}
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,task) scheduled[#scheduled+1]=task end,unschedule=function() end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
local in_worker=false;local page=1;local scope={vid='123',epoch=1};local account='owner';local current=true
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,source_sha256=string.rep('c',64),file_id=string.rep('a',64)}
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
    return v==entry and id=='42' and owner=='123' end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return native end,matches=function() return current end} end
package.preload['weread.lib.source_currentness']=function() return {capture=function() return web end,matches=function() return current end} end
local web_renewals,native_renewals=0,0
package.preload['weread.lib.native_read_recovery']=function() return {cancel=function() end,start=function(_,job,selected,opts)
    if job.recovery_attempted then return false end
    job.recovery_attempted=true;native_renewals=native_renewals+1;opts.complete(true,selected);return true
end} end
local why
package.preload['weread.lib.native_direct_position']=function() return {prepare=function(_,_,e,file,context,n,w,active)
    assert(in_worker and e==entry and file==context.file and n==native and w==web and active())
    if why then return nil,why end
    return {book_id=e.book_id,chapter_uid=e.chapter_uid,chapter_idx=e.chapter_idx,chapter_offset=123,
        file_id=e.file_id,book_version=e.book_version,raw_sha256=e.source_sha256,basis='filtered_xhtml_utf16',
        source_current=true,upload_verified=false}
end} end
local Position=require('weread.ui.native_direct_position')
local function fixture()
    scheduled={};page=1;current=true;why=nil;account='owner'
    local s={jobs={},infos=0};local doc={file='/tmp/weread/native-reader-v1/file.epub'}
    local host={ui={document=doc,view={view_mode='page'}},_reader_session_gen=1,client={},
        settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,sco) return sco==scope and current end},
        library_db={accountKey=function() return account end},isNetworkConnected=function() return true end,
        showBusy=function(self,_,cancel) self.busy_message={};s.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,message) s.infos=s.infos+1;s.message=message end,
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
expect(s.message=='The local reading position was checked against the chapter source. Cloud sync is not enabled yet.'
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
print('PASS: native position UI checks live page and never touches document from worker ('..checks..' checks)')
