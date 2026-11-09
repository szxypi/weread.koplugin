package.path='./?.lua;'..package.path
local state
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.ui.web_renewal']=function() return {
    run=function(_host,options,callback)
        state.renewals=(state.renewals or 0)+1;state.renewal={current=options.is_current,callback=callback};return true,state.renewal
    end,cancel=function() state.renewal_cancelled=true end,error_text=function() return 'fixed renewal failure' end}
end
package.preload['weread.lib.content']=function() return {book_resolved_dir=function(_settings,_id,book) return book.cache_dir or '/cache/mp' end} end
package.preload['weread.lib.mp_catalog']=function() return {MAX_RESULT=2*1024*1024,
    capture=function() return not state.invalid and {book_id='MP_WXS_42'} end,
    matches=function() return not state.auth_changed end,
    read=function() if state.worker_error then error('private error') end;return {ok=true,articles=state.new} end,
    rows=function(rows) if state.bad_rows then error('private invalid') end;return rows end} end
local Catalog=require('weread.ui.mp_catalog')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    state={account='one',jobs={},cached={{reviewId='old'}},new={{reviewId='new'}},record={progress=.2,pending_upload_position={offset=4},cache_dir='/cache/mp'},saves=0}
    local host={client={},ui={document={file='current'}},discovery_epoch=0,_reader_session_gen=1,
        library_db={accountKey=function() return state.account end},
        settings={cache_dir='/cache',get=function(_self,key,default) if key=='books' then return {MP_WXS_42=state.record} end;return default end},
        requireLogin=function() return not state.logged_out end,isNetworkConnected=function() return not state.offline end,
        showOffline=function() state.notice='offline' end,closeWeReadUI=function(self) Catalog.cancel(self);self.discovery_epoch=self.discovery_epoch+1 end,
        showBusy=function(self,_text,fn) self.busy_message={};state.dismiss=fn end,closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_self,text) state.notice=text end,getCachedMPArticles=function() return state.cached end,
        showMPArticleList=function(_self,book,rows) state.shown={book=book,rows=rows} end,
        cacheMPArticles=function(_self,id,rows)
            expect(id=='MP_WXS_42','cache account changed')
            if state.store_failed then error('private SQLite detail') end
            state.saves=state.saves+1;state.cached=rows;state.record.mp_articles=rows
        end,
        mp_catalog_worker={start=function(_self,task,callback) if state.start_failed then return false end;state.jobs[#state.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() state.cancelled=true end}}
    local book={book_id='MP_WXS_42',title='Captured',cache_dir='/cache/mp'}
    local function deliver(index,result) local job=state.jobs[index or #state.jobs];job.callback(result or job.task()) end
    return host,book,deliver
end
local host,book,deliver=fixture();expect(Catalog.start(host,book),'did not start');book.title='mutated';state.record.progress=.8;state.record.pending_upload_position.offset=12;deliver()
expect(state.saves==1 and state.shown.rows==state.new and state.shown.book.title=='Captured' and not host.busy_message and not host.mp_catalog_job,'success lost snapshot or loading')
expect(state.record.progress==.8 and state.record.pending_upload_position.offset==12,'fresh local state overwritten')
for _,change in ipairs({'account','epoch','document','file','session','cache','auth','move','timeout','clock'}) do
    host,book,deliver=fixture();Catalog.start(host,book)
    if change=='account' then state.account='two' elseif change=='epoch' then host.discovery_epoch=5
    elseif change=='document' then host.ui.document={file='current'} elseif change=='file' then host.ui.document.file='other'
    elseif change=='session' then host._reader_session_gen=2 elseif change=='cache' then host.settings.cache_dir='/other'
    elseif change=='auth' then state.auth_changed=true elseif change=='move' then state.record.cache_dir='/moved'
    elseif change=='timeout' then host.mp_catalog_job.started=os.time()-121 else host.mp_catalog_job.started=os.time()+2 end
    deliver();expect(state.saves==0 and not state.shown and not host.mp_catalog_job,'stale response applied: '..change)
end
for _,kind in ipairs({'verification','login','unavailable','private-error'}) do
    host,book,deliver=fixture();Catalog.start(host,book);deliver(1,{ok=false,kind=kind})
    if kind=='login' then state.renewal.callback(false,'renewal_unconfirmed') end
    expect(state.saves==0 and state.shown.rows==state.cached and not host.busy_message and not state.notice:find('private-error',1,true),'failure erased cache/leaked details')
    if kind=='verification' then expect(not state.notice:find('QR code',1,true),'verification rejection demanded another scan') end
end
host,book,deliver=fixture();Catalog.start(host,book);state.dismiss();deliver();expect(state.saves==0 and not state.shown and not host.mp_catalog_job,'dismissed response applied')
host,book,deliver=fixture();Catalog.start(host,book);local cancel=state.dismiss;Catalog.start(host,book);local newest=host.mp_catalog_job;cancel();deliver(1)
expect(host.mp_catalog_job==newest and host.busy_message and state.saves==0,'old callback affected new task');deliver(2);expect(state.saves==1,'new task could not finish')
for _,problem in ipairs({'logged_out','offline','invalid','start_failed','bad_rows','store_failed'}) do
    host,book,deliver=fixture();state[problem]=true;Catalog.start(host,book);if #state.jobs>0 then deliver() end
    expect(state.saves==0 and not host.mp_catalog_job,'invalid request saved: '..problem)
end
host,book,deliver=fixture();state.new={};Catalog.start(host,book);deliver();expect(state.saves==1 and #state.shown.rows==0,'valid empty page kept stale entries')
host,book,deliver=fixture();state.cached={};Catalog.start(host,book);deliver(1,{ok=false,kind='verification'})
expect(state.saves==0 and state.shown and #state.shown.rows==0,'saved empty list not restored on failure')
host,book,deliver=fixture();Catalog.start(host,book);deliver(1,{ok=false,kind='login'})
expect(state.renewals==1 and state.renewal.current() and host.mp_catalog_job and not state.shown,'login error did not wait for scoped renewal')
state.renewal.callback(true);expect(#state.jobs==2,'confirmed renewal did not re-read catalog');deliver(2)
expect(state.saves==1 and state.renewals==1,'recovered catalog not saved once')
host,book,deliver=fixture();Catalog.start(host,book);deliver(1,{ok=false,kind='login'});state.renewal.callback(true);deliver(2,{ok=false,kind='login'})
expect(state.renewals==1 and state.saves==0 and state.shown.rows==state.cached,'persistent login error renewed repeatedly')
host,book,deliver=fixture();Catalog.start(host,book);deliver(1,{ok=false,kind='login'});local pending=state.renewal
Catalog.cancel(host);pending.callback(true);expect(state.renewal_cancelled and #state.jobs==1 and state.saves==0,'cancelled renewal restarted catalog')
print('PASS: MP catalog UI scope, cancel, fallback and empty page ('..checks..' checks)')
