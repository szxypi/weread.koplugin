package.path='./?.lua;'..package.path
local login_tasks={}
local dialogs={}
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,options) dialogs[#dialogs+1]=options;return options end} end
package.preload['ffi/util']=function() return {template=function(text,value) return (text:gsub('%%1',value)) end} end
package.preload['ui/uimanager']=function() return {close=function() end,show=function() end,unschedule=function(_self,task)
    for i=#login_tasks,1,-1 do if login_tasks[i]==task then table.remove(login_tasks,i) end end
end,
    scheduleIn=function(_self,delay,task) assert(delay>=0.1);login_tasks[#login_tasks+1]=task end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
package.preload['weread.lib.source_context']=function() return {
    location=function(document) return {page=document.page} end,
    same_location=function(a,b) return a and b and a.page==b.page end,
} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(document) return {file_id=document.identity} end} end
package.preload['weread.lib.position_source']=function() return {document_metadata=function() return {metadata='bound-metadata'} end} end
local captures=0
package.preload['weread.lib.source_cloud']=function() return {
    capture=function(settings) return settings.access end,
    matches=function(settings,access) return settings.access==access end,
    fetch=function() captures=captures+1;return {book_id='900001',chapter_uid='2'} end,
    bind=function(input) return {position={book_id=input.book_id,chapter_uid='2',render_path='chapter.xhtml'},metadata='bound-metadata',request_id=input.request_id} end,
    bind_file=function(file,_remote,seq) return {file=file,identity={file_id=string.rep('a',64),book_id='900001'},
        position={chapter_uid='2'},request_id=seq} end,
    remote=function(value) return value and value.book_id and value or nil end,
    resolve=function(_client,input) return {position={book_id=input.book_id,chapter_uid='2',render_path='chapter.xhtml'},
        metadata='bound-metadata',request_id=input.request_id} end,
} end
local Request=require('weread.ui.cloud_source')
local Entry=require('weread.ui.source_position')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local state={online=true,available=true,busy=false,cancelled=0,paused=false,moves=0,navs=0}
    local document={file='/synthetic.epub',page=1,identity='original-file'}
    local jobs={}
    local host={settings={access={web={}}},ui={document=document,view={view_mode='page'}},_reader_session_gen=1,
        detectWeReadBook=function() return '900001' end,
        isNetworkOnline=function() return state.online end,
        requireLogin=function() state.login=true end,
        showOffline=function() state.offline=true end,
        showInfo=function(_self,text) state.info=text end,showTransientInfo=function(_self,text) state.notice=text end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        progress_sync={generation=0,account_generation=1,navigation_generation=0,begin_cloud_source_navigation=function(self)
                self.navigation_generation=self.navigation_generation+1;state.navs=state.navs+1 end,
            accept_cloud_source_target=function() return state.save_ok~=false end},
        source_position={can_prepare=function() return state.available end,is_busy=function() return state.busy end,
            pause=function(_self,reason) assert(reason=='cloud_source');state.paused=true end,
            resume=function(_self,reason) assert(reason=='cloud_source');state.paused=false end},
        cloud_source_worker={start=function(_self,task,callback) jobs[#jobs+1]={task=task,callback=callback};return true end,
            cancel=function() state.cancelled=state.cancelled+1 end},
        openSourcePosition=Entry.openSourcePosition,cancelCloudSourcePosition=Entry.cancelCloudSourcePosition}
    host.source_navigation={cancel=function(self)
        local job=self.job;self.job=nil
        if job then Request.navigation_cancelled(host,job) end
    end,jump=function(self,position,callback)
        host.progress_sync.navigation_generation=host.progress_sync.navigation_generation+1
        self:cancel();state.moves=state.moves+1;self.job={};state.navigation_callback=callback;state.position=position;return true
    end}
    local function deliver(index,result)
        local job=assert(jobs[index or #jobs])
        job.callback(result or job.task())
    end
    local function complete(success)
        host.source_navigation.job=nil
        state.navigation_callback(success and state.position or nil,'target_unavailable')
    end
    return {host=host,state=state,jobs=jobs,doc=document,deliver=deliver,complete=complete}
end
local f=fixture();local before=captures
expect(Request.start(f.host) and f.state.paused and f.host.busy_message and #f.jobs==1,'manual target did not start worker/busy state')
expect(captures==before and f.state.moves==0,'HTTP or navigation escaped the worker boundary')
f.deliver()
expect(f.state.moves==1 and f.host.cloud_source_request and f.state.paused,'worker result did not dispatch owned local navigation')
f.host.source_navigation.committing=true;f.doc.page=5;Request.on_view_changed(f.host)
expect(f.host.cloud_source_request~=nil,'native commit cancelled its own cloud request')
f.host.source_navigation.committing=false;f.complete(true)
expect(not f.host.cloud_source_request and not f.host.busy_message and not f.state.paused and f.state.notice,
    'successful navigation leaked busy/pause state or omitted result')
for _,change in ipairs({'page','credentials','document','session','file','new_navigation'}) do
    f=fixture();assert(Request.start(f.host))
    if change=='page' then f.doc.page=2
    elseif change=='credentials' then f.host.settings.access={web={}}
    elseif change=='document' then f.host.ui.document={file=f.doc.file,page=1,identity=f.doc.identity}
    elseif change=='session' then f.host._reader_session_gen=2
    elseif change=='new_navigation' then f.host.progress_sync.navigation_generation=f.host.progress_sync.navigation_generation+1
    else f.doc.identity='replacement-file' end
    Request.on_view_changed(f.host);f.deliver()
    expect(f.state.moves==0 and not f.host.cloud_source_request and not f.state.paused and not f.host.busy_message,
        'stale cloud target navigated: '..change)
end
f=fixture();assert(Request.start(f.host));f.state.dismiss();f.deliver()
expect(f.state.moves==0 and not f.host.cloud_source_request and not f.state.paused,'dismissed read applied late target')
f=fixture();assert(Request.start(f.host));f.deliver();f.host.source_navigation:cancel()
expect(not f.host.cloud_source_request and not f.host.busy_message and not f.state.paused,'cancelled local navigation retained cloud spinner')
f=fixture();assert(Request.start(f.host));f.deliver();f.complete(false)
expect(f.state.info:find('current page',1,true) and not f.state.info:find('location is kept',1,true),'failed native navigation claimed unchanged location')
f=fixture();f.state.save_ok=false;assert(Request.start(f.host));f.deliver();f.complete(true)
expect(f.state.info:find('storage',1,true) and not f.state.notice and not f.host.busy_message,'unsaved sync intent reported unqualified success')
f=fixture();assert(Request.start(f.host));f.deliver(nil,{error='source_changed',request_id=1})
expect(f.state.info:find('Download',1,true) and f.state.moves==0,'mismatched source guessed a target')
f=fixture();assert(Request.start(f.host));f.deliver(nil,{position={chapter_uid='2'},metadata='other',request_id=1})
expect(f.state.moves==0 and not f.host.cloud_source_request,'changed file metadata accepted')
f=fixture();assert(Request.start(f.host));local old=f.jobs[1]
assert(Request.start(f.host));local busy=f.host.busy_message
old.callback(old.task())
expect(f.host.busy_message==busy and f.host.cloud_source_request and f.state.moves==0,'old callback cancelled the new target')
f.deliver();expect(f.state.moves==1,'latest cloud target lost')
Request.cancel(f.host)
for _,kind in ipairs({'offline','resource','selection','login','reporter'}) do
    f=fixture()
    if kind=='offline' then f.state.online=false
    elseif kind=='resource' then f.state.available=false
    elseif kind=='selection' then f.state.busy=true
    elseif kind=='reporter' then f.host.read_report={job={}}
    else f.host.settings.access=nil end
    expect(not Request.start(f.host) and #f.jobs==0 and not f.host.busy_message and not f.state.paused,'unavailable cloud read started work: '..kind)
end
f=fixture();f.host.settings.access=nil
f.host.qr_login={start=function() f.state.scanning=true end}
expect(not Request.start(f.host) and #login_tasks==1 and not f.state.scanning,'missing Web scope did not show delayed login guidance')
table.remove(login_tasks,1)()
expect(f.state.scanning and #f.jobs==0,'invalid scope silently ignored login or launched cloud reads')
local function need_chapter(fixture_value)
    assert(Request.start(fixture_value.host))
    fixture_value.deliver(nil,{error='source_changed',request_id=fixture_value.host.cloud_source_sequence,
        remote={book_id='900001',chapter_uid='2'},chapter={chapterUid='2',title='Target'}})
    return assert(dialogs[#dialogs])
end
f=fixture();local prompt=need_chapter(f)
expect(f.host.cloud_source_request and not f.host.busy_message and f.state.paused,'missing cache did not yield native confirmation')
prompt.cancel_callback()
expect(not f.host.cloud_source_request and not f.state.paused,'download decline leaked request')
f=fixture();prompt=need_chapter(f);assert(Request.start(f.host));local new_request=f.host.cloud_source_request
prompt.ok_callback();prompt.cancel_callback()
expect(f.host.cloud_source_request==new_request and #f.jobs==2,'old confirmation affected replacement request')
Request.cancel(f.host)
f=fixture();prompt=need_chapter(f);f.doc.page=2;prompt.ok_callback()
expect(not f.host.cloud_source_request and f.state.moves==0,'page change accepted old confirmation')
f=fixture();prompt=need_chapter(f)
local dl={}
f.host.downloader={_active_job=dl,start=function() error('must not start') end}
prompt.ok_callback()
expect(not f.host.cloud_source_request and f.host.downloader._active_job==dl,'foreground download was replaced')
f=fixture();prompt=need_chapter(f)
local completion,download_options,owned,cancelled
f.host.downloader={start=function(self,_book,rows,_suffix,options)
    assert(rows[1].chapterUid=='2');download_options=options;completion=options.on_complete
    owned={};self._active_job=owned;return true
end,cancelJob=function(_self,job) cancelled=job end}
prompt.ok_callback()
expect(f.host.cloud_source_request.download==owned and download_options.single_chapter
    and download_options.silent_completion and download_options.offer_read==false,'download ownership/options were lost')
Request.cancel(f.host);completion(true,'/download.epub')
expect(cancelled==owned and #login_tasks==0 and #f.jobs==1,'cancelled download scheduled late reopen')
f=fixture();prompt=need_chapter(f)
f.host.downloader={start=function(self,_book,_rows,_suffix,options)
    completion=options.on_complete;self._active_job={};return true
end,cancelJob=function() end}
prompt.ok_callback();completion(true,'/download.epub');f.host.downloader._active_job=nil
expect(#login_tasks==1 and #f.jobs==1,'download reverified before downloader cleanup')
table.remove(login_tasks,1)()
expect(#f.jobs==2 and f.host.busy_message,'download completion did not recheck cloud source in worker')
-- A moving cloud chapter stops the operation rather than prompting a second download.
require('weread.lib.source_cloud').fetch=function() return {book_id='900001',chapter_uid='3'} end
f.deliver()
expect(not f.host.cloud_source_request and f.state.info:find('changed during download',1,true),'changed cloud chapter was silently followed')
for _,change in ipairs({'page','account','navigation','deadline'}) do
    f=fixture();prompt=need_chapter(f);cancelled=nil
    f.host.downloader={start=function(self,_book,_rows,_suffix,options)
        completion=options.on_complete;owned={};self._active_job=owned;return true
    end,cancelJob=function(_self,job) cancelled=job end}
    prompt.ok_callback()
    if change=='page' then f.doc.page=2
    elseif change=='account' then f.host.settings.access={web={}}
    elseif change=='navigation' then f.host.progress_sync.navigation_generation=9
    else f.host.cloud_source_request.started=os.time()-1801 end
    Request.on_view_changed(f.host);completion(true,'/late.epub')
    expect(cancelled==owned and not f.host.cloud_source_request and #login_tasks==0,'download outlived context: '..change)
end
f=fixture();prompt=need_chapter(f);f.host.cloud_source_request.started=os.time()-121;prompt.ok_callback()
expect(not f.host.cloud_source_request,'expired download confirmation was accepted')
-- A native switch returns nil on success. Resume is deferred until ReaderUI is installed,
-- uses no second HTTP snapshot, and remains bound to the new file and account.
require('weread.lib.source_cloud').fetch=function() captures=captures+1;return {book_id='900001',chapter_uid='2'} end
for _,change in ipairs({'none','cancel','page','account','navigation','identity'}) do
    f=fixture();local next_fixture=fixture();local file_id=string.rep('a',64)
    next_fixture.host.settings=f.host.settings
    next_fixture.doc.file='/cache.epub';next_fixture.doc.identity=file_id
    local after_open
    f.host.openFile=function(self,file,callback)
        assert(file=='/cache.epub' and not self.cloud_source_request)
        self._reader_session_gen=self._reader_session_gen+1
        self.progress_sync.generation=self.progress_sync.generation+1
        after_open=callback
        assert(callback({document=next_fixture.doc,weread=next_fixture.host}))
    end
    assert(Request.start(f.host));local prior=captures
    f.deliver(nil,{position={chapter_uid='2'},request_id=f.host.cloud_source_sequence,file='/cache.epub',
        identity={book_id='900001',file_id=file_id},remote={book_id='900001',chapter_uid='2'}})
    expect(after_open and next_fixture.host.cloud_source_incoming and #next_fixture.jobs==0,'switch did not defer native resume')
    local task=login_tasks[#login_tasks]
    if change=='cancel' then Request.cancel(next_fixture.host)
    elseif change=='page' then next_fixture.doc.page=2;Request.on_view_changed(next_fixture.host)
    elseif change=='account' then next_fixture.host.settings.access={web={}}
    elseif change=='navigation' then next_fixture.host.progress_sync.navigation_generation=1
    elseif change=='identity' then next_fixture.doc.identity='replaced' end
    task()
    if change=='none' then
        expect(#next_fixture.jobs==1 and not next_fixture.host.cloud_source_incoming,'valid transfer did not resume')
        next_fixture.deliver();next_fixture.complete(true)
        expect(captures==prior and next_fixture.state.moves==1,'cache transfer repeated HTTP or lost source target')
    else
        expect(#next_fixture.jobs==0 and not next_fixture.host.cloud_source_incoming,'stale incoming target started: '..change)
    end
    login_tasks={};Request.cancel(next_fixture.host)
end
print(('cloud_source_ui_spec: %d checks'):format(checks))
