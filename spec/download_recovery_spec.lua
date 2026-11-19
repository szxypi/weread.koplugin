package.path='./?.lua;'..package.path
local tasks={}
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_,_,fn) tasks[#tasks+1]=fn end,
    unschedule=function(_,fn) for i,value in ipairs(tasks) do if value==fn then table.remove(tasks,i);return end end end,
} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
package.preload['weread.lib.content']=function() return {} end
package.preload['weread.lib.shelf_source']=function() return {web_access=function() return true end} end
local renewal,request,renewals,cancels={},nil,0,0
function renewal.run(_,options,callback)
    renewals=renewals+1;request={guard=options.is_current,callback=callback};return true,request
end
function renewal.cancel(_,value) if request==value then request=nil;cancels=cancels+1 end end
function renewal.error_text() return 'renewal failed' end
package.loaded['weread.ui.web_renewal']=renewal
local state
package.loaded['weread.lib.web_authorization']={capture=function() return {
    revision=string.rep(state.cookies.wr_skey=='renewed-synthetic' and 'a' or 'b',64),
    scope={vid='900000',epoch=state.epoch}} end}
local Recovery=require('weread.ui.download_recovery')
local chapters={{chapterUid='1',title='One',wordCount=100},{chapterUid='2',title='Two',wordCount=100}}
local function fixture(version)
    tasks,request,renewals,cancels={},nil,0,0
    state={epoch=1,owner='owner',starts=0,stops=0,info=0,completed=0}
    local cookies={wr_vid='900000',wr_skey='synthetic-only'}
    state.cookies=cookies
    local host={client={},discovery_epoch=1,shelf_view={},ui={},settings={
        get=function(_,key,default) if key=='cookies' then return cookies end;return default end,
        get_auth_scope=function() return {vid='900000',epoch=state.epoch} end,
        auth_scope_matches=function(_,scope) return scope.epoch==state.epoch end,
    },library_db={accountKey=function() return state.owner end},
    isNetworkOnline=function() return true end,
    showBusy=function(self,_,cancel) self.busy_message={};state.cancel=cancel end,
    closeBusy=function(self) self.busy_message=nil end,
    showInfo=function(_,message) state.info=state.info+1;state.message=message end,
    showTransientInfo=function() end,
    downloader={start=function(_,book,list,suffix,options)
        state.starts=state.starts+1;state.job={book=book,chapters=list,suffix=suffix,options=options};return true
    end,cancelRequest=function() state.stops=state.stops+1 end},
    _full_download_recovery_worker={start=function(_,task,complete) state.worker={task=task,complete=complete};return true end,
        cancel=function() state.workers_cancelled=(state.workers_cancelled or 0)+1 end}}
    local book={book_id='900001',title='Book',bookVersion=version or 0}
    local options={on_complete=function(ok,value) state.completed=state.completed+1;state.result={ok,value} end}
    assert(Recovery.start(host,book,chapters,'full',options))
    return host,book,cookies
end
local function expire()
    state.job.options.on_complete(false,'web_expired')
    assert(#tasks==1 and renewals==0,'renewed before the old download was released')
    table.remove(tasks,1)()
    assert(renewals==1 and request and request.guard(),'renewal was not scoped to the original task')
end
local function verify(cookies)
    local old=assert(request);request=nil;cookies.wr_skey='renewed-synthetic'
    old.callback(true,{revision=string.rep('a',64)})
    assert(state.worker,'fresh catalog check was not started')
end
local host,book,cookies=fixture()
local _
assert(state.job.options.full_auth_recovery)
chapters[1].title='Later edit'
assert(state.job.chapters[1].title=='One','download retained mutable chapter records')
chapters[1].title='One'
expire();verify(cookies)
state.worker.complete({book_id='900001',chapters=chapters,version=7})
assert(state.starts==2 and state.job.book~=book and state.job.book.bookVersion==7 and book.bookVersion==0,
    'verified renewal did not restart with an isolated fresh version')
state.job.options.on_complete(true,'/cache/book.epub')
assert(state.completed==1 and state.result[1] and state.stops==0 and not host._full_download_recovery,
    'successful download was cancelled or not completed')

host,_,cookies=fixture();expire();verify(cookies)
state.worker.complete({book_id='900001',chapters=chapters,version=0})
state.job.options.on_complete(false,'web_expired');assert(#tasks==1);table.remove(tasks,1)()
assert(renewals==1 and state.starts==2 and state.completed==1 and state.info==1 and not host._full_download_recovery,
    'second 401 caused another renewal')

host,book,cookies=fixture(7);expire();verify(cookies)
state.worker.complete({book_id='900001',chapters=chapters,version=0})
assert(state.starts==2 and state.job.book.bookVersion==0 and book.bookVersion==7,
    'unknown fresh version was presented as a verified version')
Recovery.cancel(host)

host,_,cookies=fixture()
local fingerprint=require('weread.lib.worker_settings').fingerprint
local before=fingerprint(host.settings);cookies.wr_skey='updated-by-download'
state.job.options.on_reading_auth_updated(before,fingerprint(host.settings))
expire();verify(cookies);state.worker.complete({book_id='900001',chapters=chapters,version=0})
assert(state.starts==2,'verified cookie update prevented recovery')
Recovery.cancel(host)

host,_,cookies=fixture();expire();verify(cookies)
local late_worker=state.worker;Recovery.cancel(host)
late_worker.complete({book_id='900001',chapters=chapters,version=0})
assert(state.starts==1 and not host._full_download_recovery,'cancelled catalog check resumed a download')

for _,bad in ipairs({
    {book_id='900002',chapters=chapters,version=0},
    {book_id='900001',chapters={{chapterUid='1',title='Changed',wordCount=100}},version=0},
    {book_id='900001',chapters=chapters,version='7'},
    {book_id='900001',chapters=chapters,version=8},
}) do
    host,_,cookies=fixture(7);expire();verify(cookies);state.worker.complete(bad)
    assert(state.starts==1 and state.completed==1 and state.info==1 and not host._full_download_recovery,
        'unverified catalog or version resumed download')
end

for _,change in ipairs({'cancel','account','epoch','view','cookie','book'}) do
    host,book,cookies=fixture();expire()
    local old=assert(request)
    if change=='cancel' then state.cancel()
    elseif change=='account' then state.owner='other'
    elseif change=='epoch' then state.epoch=2
    elseif change=='view' then host.shelf_view={}
    elseif change=='cookie' then cookies.wr_skey='unrelated-login'
    else book.book_id='900002' end
    old.callback(true,{revision=string.rep('a',64)})
    if state.worker then state.worker.complete({book_id='900001',chapters=chapters,version=0}) end
    assert(state.starts==1 and not host._full_download_recovery,'stale recovery resumed: '..change)
end

fixture();state.job.options.on_complete(false,'rate_limited')
assert(renewals==0 and #tasks==0 and state.completed==1 and state.stops==0,'non-401 failure attempted renewal')
host,_,cookies=fixture();expire();cookies.wr_skey='renewed-synthetic'
local stale=request;request=nil;stale.callback(true,{revision=string.rep('b',64)})
assert(state.starts==1 and not host._full_download_recovery,'foreign renewal receipt was accepted')
host=fixture();state.job.options.on_complete(false,'web_expired');Recovery.cancel(host)
assert(#tasks==0 and state.stops==1 and renewals==0,'cancellation left a scheduled renewal')
print('download_recovery_spec: scoped full-book renewal passed')
