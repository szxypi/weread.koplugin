package.path='./?.lua;'..package.path
local Service=require('weread.lib.source_position')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local book,chapter={book_id='synthetic',bookVersion=7},{chapterUid=11}
local raw='<body>abcdefghijklmnopqrstuvwx</body>'
local path='OEBPS/text/chapter.xhtml'
local captured=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(raw))
local identity=assert(Identity.decode(root))
local metadata=assert(Source.bind(captured,identity,path,Crypto.sha256_hex(raw)))
local function document(file)
    return {file=file or '/book.epub',location={page=1,pos=0,xpointer='point-1',view_mode='page'},
        getDocumentFileContent=function(_self,name)
            if name==Identity.PATH then return root end
            if name==Source.path_meta_path(path) then return metadata end
            error('body must not be read on UI thread')
        end}
end
local doc=document()
local account='owner-1'
local available,busy=true,false
local tasks,clock={},0
local scheduler={
    scheduleIn=function(_self,delay,fn) tasks[#tasks+1]={time=clock+delay,fn=fn} end,
    unschedule=function(_self,fn) for i=#tasks,1,-1 do if tasks[i].fn==fn then table.remove(tasks,i) end end end,
}
local function next_task()
    table.sort(tasks,function(a,b) return a.time<b.time end)
    local item=table.remove(tasks,1)
    assert(item,'missing scheduled task');clock=item.time;item.fn()
end
local function drain()
    local count=0
    while #tasks>0 do count=count+1;assert(count<100,'scheduler loop');next_task() end
end
local worker={jobs={},cancel=function(self) if self.active then self.active.cancelled=true end self.active=nil end}
function worker:start(task,callback)
    local job={task=task,callback=callback}
    self.jobs[#self.jobs+1],self.active=job,job
    return true
end
local frame
local yields=0
local context={location=function(document_) return document_.location end,
    capture=function(document_,book_id,location,options)
        if yields>0 then yields=yields-1;options.yield() end
        if not options.is_current() then return {error='cancelled'} end
        frame={file=document_.file,book_id=book_id,chapter_uid='11',render_path=path,identity=identity,metadata=metadata,
            text='abcdefghijklmnopqrstuvwx',point_offset=12,location=location}
        return frame
    end}
local events={}
local service=Service:new{scheduler=scheduler,worker=worker,context=context,get_document=function() return doc end,
    get_book_id=function() return 'synthetic' end,get_account=function() return account end,
    can_prepare=function() return available end,is_busy=function() return busy end,
    now=function() return clock end,on_change=function(state) events[#events+1]=state end}
local function value(request_id)
    return {request_id=request_id,position={book_id='synthetic',chapter_uid='11',chapter_offset=18,
        file_id=identity.file_id,book_version=7,raw_sha256=captured.raw_sha256,render_path=path,
        basis='filtered_xhtml_utf16',upload_verified=false}}
end
service:on_reader_ready();drain()
expect(#worker.jobs==1 and service.state=='preparing','reader did not prepare position')
expect(not frame.account and not frame.document,'worker input included account/native document')
local initial_request=service.sequence
worker.jobs[1].callback(value(initial_request))
expect(service.state=='ready' and service:current().chapter_offset==18,'source result was not accepted')
local snapshot=service:current();snapshot.chapter_offset=999
expect(service:current().chapter_offset==18,'caller mutated source snapshot')
local callback_count=0
service:check(function(position) callback_count=callback_count+1;expect(position.chapter_uid=='11','manual check returned wrong chapter') end)
expect(callback_count==1 and #worker.jobs==1,'ready check launched another worker')
service:on_view_changed();drain()
expect(#worker.jobs==1,'unchanged frame restarted source work')
-- Forward/back navigation owns a new request even when the final page is the
-- same. An old result never revives after that intermediate page change.
doc.location={page=2,pos=100,xpointer='point-2',view_mode='page'}
service:on_view_changed();drain()
local second=worker.jobs[2]
local second_id=service.sequence
doc.location={page=1,pos=0,xpointer='point-1',view_mode='page'}
service:on_view_changed();drain()
expect(second.cancelled and not service:current(),'page change retained a previous source snapshot')
second.callback(value(second_id))
expect(not service:current(),'late page result committed')
worker.jobs[3].callback(value(service.sequence))
expect(service:current(),'new page result was lost')
-- Account and reading generations are independent of pathname/content equality.
service:on_view_changed(true);drain()
local old=worker.jobs[#worker.jobs];local old_id=service.sequence
account='owner-2';service:on_account_changed();drain()
old.callback(value(old_id))
expect(not service:current(),'old account result committed')
worker.jobs[#worker.jobs].callback(value(service.sequence))
expect(service:current(),'new account failed to prepare its own position')
service:on_view_changed(true);drain();old=worker.jobs[#worker.jobs];old_id=service.sequence
doc=document()
service:on_reader_ready();drain();old.callback(value(old_id))
expect(not service:current(),'reopened document inherited old native scope')
worker.jobs[#worker.jobs].callback(value(service.sequence))
expect(service:current(),'reopened document result was lost')
-- A mutable path on the same Lua document also changes scope.
doc.file='/copy.epub'
local missing,state=service:current()
expect(not missing and state=='stale','changed pathname reused source result')
service:on_view_changed();drain()
worker.jobs[#worker.jobs].callback(value(service.sequence))
expect(service:current(),'new pathname did not prepare')
-- Pause causes are stacked, and no old worker may commit across suspend.
service:on_view_changed(true);drain();old=worker.jobs[#worker.jobs];old_id=service.sequence
service:pause('reader');service:pause('suspend');old.callback(value(old_id))
expect(service.state=='paused' and not service:current(),'paused reader accepted an old result')
service:resume('reader');expect(service.state=='paused','reading resume bypassed device suspend')
local paused_reason
service:check(function(_position,reason) paused_reason=reason end)
expect(paused_reason=='paused','paused manual check attempted preparation')
service:resume('suspend');drain()
worker.jobs[#worker.jobs].callback(value(service.sequence))
expect(service:current(),'resume did not create fresh source scope')
service:on_view_changed(true);drain()
local extra=value(service.sequence);extra.position.text='BODY_CANARY';extra.position.raw='RAW_CANARY'
extra.position.chapter_title='Original title'
worker.jobs[#worker.jobs].callback(extra)
expect(service:current().chapter_title=='Original title' and not service:current().text and not service:current().raw,
    'unrecognized worker fields escaped retained metadata')
-- Resource pressure defers work, preserving the main reader and bounded retry.
available=false;service:on_view_changed(true);next_task()
expect(service.state=='deferred','low memory did not defer source preparation')
local jobs_before=#worker.jobs
available=true;drain()
expect(#worker.jobs==jobs_before+1,'resource recovery did not prepare')
worker.jobs[#worker.jobs].callback(value(service.sequence))
available=false;service:on_view_changed(true);drain()
expect(service.state=='unavailable' and not service.job,'resource retry was unbounded')
available=true
-- Highlight/selection interaction defers native extraction, not just the worker.
busy=true;service:on_view_changed(true);next_task()
expect(service.state=='deferred','selection did not defer context extraction')
busy=false;drain();worker.jobs[#worker.jobs].callback(value(service.sequence))
expect(service:current(),'selection recovery lost preparation')
-- Native extraction can yield; changing page before its next slice cancels it.
yields=1;service:on_view_changed(true);next_task()
expect(service.job and service.job.thread,'cooperative native context did not yield')
doc.location={page=3,pos=200,xpointer='point-3',view_mode='scroll'}
service:on_view_changed();drain();worker.jobs[#worker.jobs].callback(value(service.sequence))
expect(service:current(),'new scroll frame failed')
-- Reject a correctly shaped packet whose owner/source identity is wrong.
service:on_view_changed(true);drain()
worker.jobs[#worker.jobs].callback({request_id=service.sequence,position=true})
expect(not service:current() and service.state=='unavailable','malformed worker result was not rejected')
for _,field in ipairs({'request_id','book_id','chapter_uid','file_id','raw_sha256','render_path','book_version','basis','upload_verified','chapter_offset'}) do
    service:on_view_changed(true);drain()
    local packet=value(service.sequence)
    if field=='request_id' then packet.request_id=999999 else packet.position[field]='wrong' end
    worker.jobs[#worker.jobs].callback(packet)
    expect(not service:current(),'foreign worker packet accepted: '..field)
end
service:on_view_changed(true);drain();old=worker.jobs[#worker.jobs];old_id=service.sequence
service:stop();old.callback(value(old_id))
expect(service.state=='idle' and not service:current() and #tasks==0,'close retained source work')
expect(events[#events]=='idle','source status change was not delivered')
local held=value(service.sequence).position;held.retained_source_target=true
service.get_retained=function() return held end
service:on_reader_ready();drain()
expect(service:current().retained_source_target,'bound target was not exposed by source service')
local previous_jobs=#worker.jobs
service:on_view_changed(true)
held=nil
expect(not service:current(),'invalidated held result escaped through the ordinary result cache')
drain()
expect(#worker.jobs==previous_jobs+1,'post-event marker change did not restart actual viewport capture')
worker.jobs[#worker.jobs].callback(value(service.sequence))
expect(service:current() and not service:current().retained_source_target,'held result survived fresh viewport capture')
held=value(service.sequence).position;held.retained_source_target=true
service:on_view_changed(true);drain();service:pause('suspend')
expect(not service:current(),'paused source service exposed retained target')
service:resume('suspend');drain();expect(service:current().retained_source_target,'retained target did not resume')
held=nil
expect(not service:current(),'same-line marker change without movement event exposed held result')
local pending=#worker.jobs;drain()
expect(#worker.jobs==pending+1,'observed same-line marker change did not schedule a fresh capture')
service:stop();expect(not service:current(),'stopped source service exposed retained target')
print(('source_position_spec: %d checks'):format(checks))
