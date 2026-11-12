package.path='./?.lua;'..package.path
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local queue,warnings={},{}
package.preload['ui/uimanager']=function() return {
    close=function() end,scheduleIn=function(_self,delay,callback) assert(delay>=.1);queue[#queue+1]=callback end,
} end
for _,name in ipairs({'ui/bidi','ui/widget/textviewer','ui/widget/confirmbox','ui/widget/inputdialog',
        'weread.lib.content','weread.lib.book_reviews','weread.ui.book_reviews_view'}) do
    package.preload[name]=function() return {} end
end
package.preload['weread.lib.plugin_util']=function() return {
    tr=function(text) return text end,T=function(text) return text end,log_error=tostring,display_error=tostring,
    file_exists=function() return false end,
} end
package.preload['weread.lib.logger']=function() return {
    warn=function(value) warnings[#warnings+1]=value end,
    scoped=function() return {} end,
} end
local Library=require('weread.ui.library')
local function tick() local callback=table.remove(queue,1);assert(callback,'missing poll');callback() end
local function fixture()
    queue,warnings={},{}
    local workers,files={},{}
    local host={shelf_cover_generation=1,isNetworkOnline=function() return true end}
    for key,value in pairs(Library) do host[key]=value end
    local count,reads,redraws,downloads=0,0,0,0
    local runner={}
    runner.run=function(task)
        for _,worker in pairs(workers) do assert(worker.reaped,'new cover overlapped a retiring child') end
        count=count+1;workers[count]={task=task,kills=0};return count,count+100
    end
    runner.write_all=function(fd,value) workers[fd-100].result=value end
    runner.is_done=function(pid)
        if workers[pid].done then workers[pid].reaped=true;return true end
        return false
    end
    runner.terminate=function(pid)
        local worker=workers[pid];worker.kills=worker.kills+1
        if worker.fail_kill then worker.fail_kill=false;error('synthetic termination failure') end
    end
    runner.read_all=function(fd) reads=reads+1;return workers[fd-100].result end
    host.shelf_cover_subprocess=runner
    local cache={MAX_IMAGE_BYTES=3*1024*1024,pathFor=function(_self,book) return files[book] end,
        sourcePathFor=function() end,thumbnailFromCached=function(_self,book) return files[book] end,
        store=function(_self,book) files[book]='/cache/'..book.bookId;return files[book] end,prune=function() end}
    host.getShelfCoverCache=function() return cache end
    host.client={get_binary=function() downloads=downloads+1;return 'synthetic bitmap' end}
    local function view() return {page=1,page_size=2} end
    local function book(id) return {bookId=id,cover='https://example.invalid/'..id} end
    local first,tail=book('first'),book('tail')
    local options={on_redraw=function() redraws=redraws+1 end}
    local function start(target,items)
        host.shelf_view=target;host:fetchVisibleShelfCovers(target,items or {first,tail},options)
        return host.shelf_cover_job
    end
    local function finish(job,success)
        if success then workers[job.pid].task(job.pid,job.read_fd) end
        workers[job.pid].done=true;tick()
    end
    return {host=host,workers=workers,files=files,start=start,finish=finish,view=view,first=first,tail=tail,
        stats=function() return {runs=count,reads=reads,redraws=redraws,downloads=downloads} end}
end

local f=fixture();local host=f.host;local job=f.start(f.view())
host:closeWeReadUI()
expect(job.cancelled and host.shelf_cover_job==job and job.read_fd~=nil,'closing discarded an unreaped job')
host:closeWeReadUI()
expect(f.workers[job.pid].kills==1 and not host.shelf_cover_pending,'repeated close killed twice or kept queued work')
f.finish(job)

f=fixture();host=f.host;job=f.start(f.view());host:cancelShelfCovers();tick()
expect(f.workers[job.pid].kills==2 and host.shelf_cover_job==job,'live child did not retry a missed cancellation signal')
f.finish(job)
expect(f.stats().reads==1 and not host.shelf_cover_job,'retried cancellation lost its pipe or ownership')
expect(not host.shelf_cover_job and f.stats().reads==1 and f.stats().runs==1,'cancelled child was not reaped/drained once')
expect(f.stats().redraws==0 and #warnings==0,'expected cancellation redrew the page or logged a failure')

f=fixture();host=f.host;job=f.start(f.view());host:cancelShelfCovers()
local next_view=f.view();f.start(next_view,{f.tail})
expect(host.shelf_cover_job==job and host.shelf_cover_pending.view==next_view,'reopen started before old child was reaped')
f.finish(job);local next_job=host.shelf_cover_job
expect(next_job and next_job~=job and f.stats().runs==2,'reopen did not start newest queued page')
f.finish(next_job,true)
expect(f.stats().downloads==1 and f.stats().redraws==1 and f.files[f.tail],'reopened cover did not render through the new batch')

f=fixture();host=f.host;job=f.start(f.view());local second=f.view();f.start(second,{f.tail})
local third=f.view();f.start(third,{f.tail})
expect(job.cancelled and f.workers[job.pid].kills==1 and host.shelf_cover_pending.view==third,'page switch did not keep only latest work')
host:cancelShelfCovers(true)
expect(host.shelf_cover_resume.view==third and not host.shelf_cover_pending,'suspend lost the newest visible page')
host:resumeShelfCovers()
expect(not host.shelf_cover_resume and host.shelf_cover_pending.view==third,'resume bypassed retiring writer or retained replay')
f.finish(job);f.finish(host.shelf_cover_job,true)
expect(f.stats().downloads==1 and f.stats().redraws==1,'resume fetched a stale page or duplicated work')
host:resumeShelfCovers()
expect(f.stats().runs==2,'repeated wake replayed completed covers')

for _,event in ipairs({'closeWeReadUI','onWeReadAccountChanged'}) do
    f=fixture();host=f.host;job=f.start(f.view());host:cancelShelfCovers(true)
    host[event](host);host:resumeShelfCovers();f.finish(job)
    expect(not host.shelf_cover_resume and not host.shelf_cover_job and f.stats().runs==1,event..' left resumable work')
end

f=fixture();local target=f.view();job=f.start(target,{f.first})
f.start(target,{f.first})
expect(f.workers[job.pid].kills==0,'same-page duplicate cancelled useful work')
f.finish(job,true)
expect(f.stats().runs==1 and f.stats().downloads==1,'same-page duplicate spawned another worker')

f=fixture();host=f.host;job=f.start(f.view());f.files[f.first]='/cache/committed-before-close'
host:cancelShelfCovers();f.workers[job.pid].result='ok';f.finish(job)
expect(f.files[f.first] and f.stats().redraws==0 and f.stats().runs==1,'cancel race deleted valid cache or continued stale batch')

f=fixture();host=f.host;job=f.start(f.view());f.workers[job.pid].fail_kill=true
host:cancelShelfCovers()
expect(job.cancelled and not job.termination_requested and host.shelf_cover_job==job,'failed signal discarded ownership')
host:cancelShelfCovers();host:cancelShelfCovers()
expect(f.workers[job.pid].kills==2 and #warnings==1,'failed signal could not retry once or successful signal repeated')
f.finish(job)

f=fixture();host=f.host;job=f.start(f.view(),{f.first});job.started_at=os.time()-31
tick();tick()
expect(f.workers[job.pid].kills==2 and host.shelf_cover_job==job,'timeout stopped retrying or dropped an unreaped child')
f.finish(job)
expect(not host.shelf_cover_job and f.stats().reads==1,'timed-out worker did not drain once')

local Lifecycle=require('weread.lib.reader_lifecycle')
for _,event in ipairs({'onReaderReady','onCloseDocument','onSuspend'}) do
    local argument,called
    local ok,reason=pcall(Lifecycle[event],{cancelShelfCovers=function(_self,resume) argument=resume;called=true;error('hook-reached',0) end})
    expect(not ok and reason=='hook-reached' and called and argument==(event=='onSuspend' and true or nil),event..' omitted cover cancellation')
end
local ok,reason=pcall(Lifecycle.onResume,{resumeShelfCovers=function() error('resume-reached',0) end})
expect(not ok and reason=='resume-reached','wake omitted deferred cover work')
print(('shelf_cover_cancel_spec: %d checks'):format(checks))
