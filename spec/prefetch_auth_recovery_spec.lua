package.path='./?.lua;'..package.path
local tasks={}
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_,_,task) tasks[#tasks+1]=task end,
    unschedule=function(_,task) for i=#tasks,1,-1 do if tasks[i]==task then table.remove(tasks,i) end end end,
} end
local state
package.preload['weread.lib.web_authorization']=function() return {capture=function()
    if state.capture_fails then error('unavailable',0) end
    return {revision=state.revision,scope={vid='900000',epoch=state.epoch}}
end} end
package.preload['weread.ui.web_renewal']=function() return {service=function(host) return host.web_renewal end} end
package.preload['weread.ui.book_reading']=function() return {catalog=function(rows)
    if type(rows)~='table' or #rows==0 then return nil end
    local result={}
    for i,row in ipairs(rows) do
        if type(row.title)~='string' then return nil end
        result[i]={chapterUid=tostring(row.chapterUid),title=row.title,chapterIdx=row.chapterIdx,
            wordCount=row.wordCount or 0,level=row.level or 1}
    end
    return result
end} end
local Recovery=require('weread.ui.prefetch_auth_recovery')
local function fixture()
    tasks={}
    state={epoch=1,revision=string.rep('a',64),online=true,starts=0,cancels=0,restarts=0,enabled=true,
        cookies={wr_vid='900000',wr_skey='synthetic-old'}}
    local document={file='/synthetic/chapter.epub'}
    local settings={get=function(_,key,default)
        if key=='cache' then return {auto_prefetch_next_chapter=state.enabled} end
        if key=='cookies' then return state.cookies end
        if key=='api_key' then return state.api_key or default end
        return default
    end,get_auth_scope=function() return {vid='900000',epoch=state.epoch} end,
        auth_scope_matches=function(_,scope) return scope.epoch==state.epoch end}
    local service={}
    function service:start(options,callback)
        state.starts=state.starts+1
        self.job={options=options,callback=callback}
        return true,self.job
    end
    function service:cancel(job)
        if self.job==job then self.job=nil;state.cancels=state.cancels+1 end
    end
    local worker={start=function(self,_task,callback) self.callback=callback;return true end,
        cancel=function(self) self.callback=nil end}
    local host={settings=settings,ui={document=document},downloader={},web_renewal=service,
        _prefetch_auth_recovery_worker=worker,
        _reader_session_gen=1,_current_weread_book_id='900001',
        isNetworkConnected=function() return state.online end,
        maybePrefetchNextChapter=function(_,id,recovered)
            assert(id=='900001' and recovered.chapter_uid=='2')
            state.recovered=recovered
            state.restarts=state.restarts+1
        end}
    return host,{book_id='900001',bookVersion=7},{chapterUid=2,title='Synthetic',wordCount=100},document,service
end
local function dispatch()
    local task=table.remove(tasks,1);assert(task);task()
end
local host,book,chapter=fixture()
local service=host.web_renewal
assert(Recovery.start(host,book,chapter) and #tasks==1 and state.starts==0)
dispatch();local job=assert(service.job)
assert(state.starts==1 and job.options.expected_revision==string.rep('a',64) and job.options.is_current())
state.cookies.wr_skey='synthetic-new';state.revision=string.rep('b',64);service.job=nil
job.callback(true,{revision=state.revision,scope={vid='900000',epoch=1}})
assert(host._prefetch_auth_recovery_worker.callback and state.restarts==0,'renewal skipped catalog verification')
host._prefetch_auth_recovery_worker.callback{book_id='900001',version=7,
    chapters={{chapterUid=2,title='Synthetic',wordCount=100}}}
assert(state.restarts==1 and not host._prefetch_auth_recovery and not Recovery.start(host,book,chapter),
    'confirmed renewal did not restart once or repeated after another 401')
assert(state.recovered.version==7 and state.recovered.previous_version==7)
host,book,chapter=fixture();service=host.web_renewal;assert(Recovery.start(host,book,chapter));dispatch();job=assert(service.job)
service.job=nil;job.callback(true,{revision=string.rep('a',64)})
host._prefetch_auth_recovery_worker.callback{book_id='900001',version=0,
    chapters={{chapterUid=2,title='Synthetic',wordCount=100}}}
assert(state.restarts==1 and state.recovered.version==0 and state.recovered.previous_version==7 and book.bookVersion==7,
    'unknown fresh version was asserted as known or changed the original book')
host,book,chapter=fixture();service=host.web_renewal;assert(Recovery.start(host,book,chapter));dispatch();job=assert(service.job)
service.job=nil;job.callback(true,{revision=string.rep('a',64)})
local stale_catalog=host._prefetch_auth_recovery_worker.callback
assert(Recovery.cancel(host));stale_catalog{book_id='900001',version=7,chapters={{chapterUid=2,title='Synthetic',wordCount=100}}}
assert(state.restarts==0 and not host._prefetch_auth_recovery,'cancelled catalog check resumed prefetch')
for _,change in ipairs({'account','credentials','book','chapter'}) do
    host,book,chapter=fixture();service=host.web_renewal;assert(Recovery.start(host,book,chapter));dispatch();job=assert(service.job)
    service.job=nil;job.callback(true,{revision=string.rep('a',64)})
    local callback=host._prefetch_auth_recovery_worker.callback
    if change=='account' then state.epoch=2
    elseif change=='credentials' then state.cookies.wr_skey='another-session'
    elseif change=='book' then book.book_id='900002'
    else chapter.chapterUid=3 end
    callback{book_id='900001',version=7,chapters={{chapterUid=2,title='Synthetic',wordCount=100}}}
    assert(state.restarts==0 and not host._prefetch_auth_recovery,'stale catalog result resumed prefetch: '..change)
end
for _,bad in ipairs({{book_id='900001',version=8,chapters={{chapterUid=2,title='Synthetic',wordCount=100}}},
    {book_id='900001',version=7,chapters={{chapterUid=2,title='Changed',wordCount=100}}},
    {book_id='900001',version=7,chapters={{chapterUid=3,title='Synthetic',wordCount=100}}},
    {book_id='900002',version=7,chapters={{chapterUid=2,title='Synthetic',wordCount=100}}},
    {error='unavailable'}}) do
    host,book,chapter=fixture();service=host.web_renewal;assert(Recovery.start(host,book,chapter));dispatch();job=assert(service.job)
    service.job=nil;job.callback(true,{revision=string.rep('a',64)})
    assert(host._prefetch_auth_recovery_worker.callback)
    host._prefetch_auth_recovery_worker.callback(bad)
    assert(not host._prefetch_auth_recovery and state.restarts==0,'changed catalog resumed prefetch')
end
for _,change in ipairs({'account','document','file','session','book','chapter','title','active','offline','disabled','key','receipt'}) do
    local document
    host,book,chapter,document,service=fixture();assert(Recovery.start(host,book,chapter));dispatch();job=assert(service.job)
    if change=='account' then state.epoch=2
    elseif change=='document' then host.ui.document={file=document.file}
    elseif change=='file' then document.file='/different.epub'
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='book' then book.book_id='900002'
    elseif change=='chapter' then chapter.chapterUid=3
    elseif change=='title' then chapter.title='Changed'
    elseif change=='active' then host.downloader._active_job={}
    elseif change=='offline' then state.online=false
    elseif change=='disabled' then state.enabled=false
    elseif change=='key' then state.api_key='different'
    else state.revision=string.rep('b',64) end
    service.job=nil;job.callback(true,{revision=string.rep('a',64)})
    assert(state.restarts==0 and not host._prefetch_auth_recovery,'stale renewal restarted prefetch: '..change)
end
host,book,chapter=fixture();assert(Recovery.start(host,book,chapter));assert(Recovery.cancel(host))
assert(#tasks==0 and state.starts==0,'cancel before dispatch left scheduled work')
host,book,chapter=fixture();service=host.web_renewal;assert(Recovery.start(host,book,chapter));dispatch();job=assert(service.job)
assert(Recovery.cancel(host) and state.cancels==1 and not service.job)
job.callback(true,{revision=string.rep('a',64)})
assert(state.restarts==0 and not host._prefetch_auth_recovery,'cancelled renewal restarted prefetch')
for _,reason in ipairs({'renewal_unconfirmed','save_failed','verification_unconfirmed'}) do
    host,book,chapter=fixture();service=host.web_renewal;assert(Recovery.start(host,book,chapter));dispatch();job=assert(service.job)
    job.callback(false,reason)
    assert(state.cancels==1 and not service.job and not host._prefetch_auth_recovery and state.restarts==0
        and not Recovery.start(host,book,chapter),'failed renewal retained work or was retried: '..reason)
end
host,book,chapter=fixture();assert(Recovery.start(host,book,chapter));state.cookies.wr_skey='foreign';dispatch()
assert(state.starts==0 and not host._prefetch_auth_recovery,'changed credential dispatched renewal')
host,book,chapter=fixture();assert(Recovery.start(host,book,chapter));host._web_renewal_request={};dispatch()
assert(state.starts==0 and not host._prefetch_auth_recovery,'background renewal replaced a foreground renewal')
print('prefetch_auth_recovery_spec: scoped single renewal and cancellation passed')
