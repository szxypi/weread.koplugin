package.path='./?.lua;'..package.path
local state
package.preload['ui/uimanager']=function() return {scheduleIn=function(_self,_delay,fn) state.pending=fn end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
package.preload['weread.lib.mp_download_stage']=function() return {} end
package.preload['weread.lib.mp_download']=function() return {
    capture=function() if not state.invalid then return {book_id='MP_WXS_1',root='/cache/book',key='key'} end end,
    matches=function() return not state.auth_changed end,write=function() return {ok=true} end} end
local Download=require('weread.ui.mp_download')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    state={books={MP_WXS_1={progress=.4,pending_upload_position={offset=12}}},jobs={},account='one',cleanups=0,closed=0,commits=0}
    local host={discovery_epoch=0,_reader_session_gen=1,client={},ui={document={file='one'}},
        settings={cache_dir='/cache',get=function(_self,key) if key=='books' then return state.books end end,
            set=function(_self,_key,value) if state.store_failed then error('private SQLite error') end;state.books=value end,flush=function() state.flushed=true end},
        library_db={accountKey=function() return state.account end},requireLogin=function() return not state.logged_out end,
        isNetworkConnected=function() return not state.offline end,showOffline=function() state.notice='offline' end,
        closeWeReadUI=function(self) Download.cancel(self);self.discovery_epoch=self.discovery_epoch+1 end,
        showBusy=function(self,_text,fn) self.busy_message={};state.dismiss=fn end,
        closeBusy=function(self) self.busy_message=nil end,showInfo=function(_self,text) state.notice=text end,
        openFile=function(_self,path) state.opened=path end,
        create_mp_stage=function()
            if state.no_space then return nil end
            return {close=function() state.closed=state.closed+1 end,cleanup=function() state.cleanups=state.cleanups+1 end,
                commit=function(_self,result) if result and result.ok and not state.commit_failed then state.commits=state.commits+1;return '/cache/book/article.html' end end}
        end,
        mp_download_worker={runner={done=function() return not state.running end},
            start=function(self,task,callback)
                if state.start_failed then return false end
                self.job={pid=#state.jobs+1};state.jobs[#state.jobs+1]={task=task,callback=callback};return true
            end,cancel=function() state.cancelled=true end}}
    local function deliver(index,result) local j=state.jobs[index or #state.jobs];j.callback(result or j.task()) end
    return host,deliver
end
local host,deliver=fixture();expect(Download.start(host,{},{}),'start failed');deliver()
expect(state.commits==1 and state.opened and not host.mp_download_job and not host.busy_message,'completed job not opened')
expect(state.books.MP_WXS_1.progress==.4 and state.books.MP_WXS_1.pending_upload_position.offset==12 and state.books.MP_WXS_1.cache_dir=='/cache/book','progress or intent overwritten')
for _,change in ipairs({'account','epoch','document','file','session','auth','cache','move','timeout'}) do
    host,deliver=fixture();Download.start(host,{},{})
    if change=='account' then state.account='two' elseif change=='epoch' then host.discovery_epoch=9
    elseif change=='document' then host.ui.document={file='one'} elseif change=='file' then host.ui.document.file='two'
    elseif change=='session' then host._reader_session_gen=2 elseif change=='auth' then state.auth_changed=true
    elseif change=='cache' then host.settings.cache_dir='/other' elseif change=='move' then state.books.MP_WXS_1.cache_dir='/moved'
    else host.mp_download_job.started=os.time()-121 end
    deliver();expect(not state.opened and state.commits==0 and state.cleanups==1,'stale download published: '..change)
end
host,deliver=fixture();Download.start(host,{},{});state.running=true;state.dismiss()
expect(not host.mp_download_job and state.cleanups==0 and state.closed==1,'cancel deleted stage before child exit or held fd')
state.running=false;state.pending();expect(state.cleanups==1,'reaped child stage not removed');deliver();expect(not state.opened,'cancelled result opened file')
host,deliver=fixture();Download.start(host,{},{});local old=state.dismiss;Download.start(host,{},{});local latest=host.mp_download_job
old();deliver(1);expect(host.mp_download_job==latest and host.busy_message and not state.opened,'old callback affected newer job');deliver(2);expect(state.opened and state.commits==1,'new job did not publish')
for _,change in ipairs({'offline','logged_out','invalid','no_space','start_failed','commit_failed'}) do
    host,deliver=fixture();state[change]=true;Download.start(host,{},{})
    if #state.jobs>0 then deliver() end
    expect(not state.opened and not host.mp_download_job,'invalid or failed download opened: '..change)
end
host,deliver=fixture();Download.start(host,{},{});deliver(1,{error='private-error'})
expect(not state.opened and state.cleanups==1 and not state.notice:find('private-error',1,true),'worker error leaked or published')
host,deliver=fixture();Download.start(host,{},{});state.store_failed=true;deliver()
expect(state.commits==1 and not state.opened and not host.mp_download_job and not host.busy_message and state.cleanups==0
    and state.notice:find('article was downloaded',1,true) and not state.notice:find('private SQLite',1,true),'metadata failure crashed or deleted complete cache')
print('PASS: MP download UI ownership and cancellation ('..checks..' checks)')
