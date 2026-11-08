package.path='./?.lua;'..package.path
local login_tasks={}
package.preload['ui/uimanager']=function() return {close=function() end,
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
    fetch=function() captures=captures+1;return {} end,
    bind=function(input) return {position={book_id=input.book_id,chapter_uid='2',render_path='chapter.xhtml'},
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
        progress_sync={navigation_generation=0,begin_cloud_source_navigation=function(self)
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
f=fixture();assert(Request.start(f.host));f.deliver(nil,{error='source_changed'})
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
print(('cloud_source_ui_spec: %d checks'):format(checks))
