package.path='./?.lua;'..package.path
local w={}
local function reset() w={current=true,valid_file=true,native=true,web=true,jobs={},notices={},downloads=0,cancels=0} end
reset()
local info={mode='file',ino=1,dev=1,size=100,modification=20}
local owner={file='/synthetic.epub',stat=info,book_id='456',scope={vid='123'},auth='revision',
    source={chapter_uid='7',metadata='meta',identity={file_id=string.rep('a',64)}}}
package.loaded['ui/uimanager']={}
package.loaded['weread.lib.plugin_util']={tr=function(value) return value end}
package.loaded['libs/libkoreader-lfs']={symlinkattributes=function() if w.valid_file then return info end end}
package.loaded['weread.lib.native_read_access']={capture=function() if w.native then return {scope=owner.scope} end end}
package.loaded['weread.lib.read_access']={capture=function() if w.web then return {web={}} end end}
package.loaded['weread.lib.worker_settings']={fingerprint=function() return 'revision' end,
    capture=function() return function() return w.auth end end,merge=function() return not w.merge_fail end}
package.loaded['weread.lib.translation_generation_journal']={new=function() return {} end}
package.loaded['weread.ui.translation_fetch']={capture_owner=function() return owner end,is_current=function() return w.current end,
    start=function() w.downloads=w.downloads+1;return true end}
package.loaded['weread.lib.translation_generation_task']={run=function(_client,_settings,_selected,_web,input,_journal,options)
    assert(input.book_id=='456' and input.chapter_uid=='7' and input.file_id==owner.source.identity.file_id)
    if not options.is_current() then return {kind='unavailable'} end
    return {kind=w.kind or 'pending'}
end}
local Generation=require('weread.ui.translation_generation')
local function host()
    return {settings={auth_scope_matches=function() return true end},client={},library_db={},
        closeWeReadUI=function() end,isNetworkOnline=function() return not w.offline end,
        requireLogin=function() return not w.no_web_login end,
        showOffline=function() w.offline_notice=true end,showInfo=function(_self,message) w.notices[#w.notices+1]=message end,
        showBusy=function(self,_message,cancel) self.busy_message={};w.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        translation_generation_worker={start=function(_self,task,callback)
            if w.start_failed then return false end
            w.jobs[#w.jobs+1]={task=task,callback=callback};return true
        end,cancel=function() w.cancels=w.cancels+1 end}}
end
local function deliver(index,value)
    local job=w.jobs[index or #w.jobs];job.callback(value or job.task())
end
local h=host();assert(Generation.start(h) and h.translation_generation_job and h.busy_message)
deliver();assert(not h.translation_generation_job and not h.busy_message and #w.notices==1 and w.notices[1]:find('still being prepared',1,true))
reset();h=host();w.kind='available';assert(Generation.start(h));deliver()
assert(w.downloads==1 and not h.busy_message,'available translation was not downloaded')
reset();h=host();w.kind='stopped';assert(Generation.start(h));deliver()
assert(w.notices[1]:find('not available for this chapter',1,true),'stopped status not explained')
reset();h=host();w.kind='unconfirmed';assert(Generation.start(h));deliver()
assert(w.notices[1]:find('will not be sent again',1,true),'unknown response was presented as safe to retry')
reset();h=host();assert(Generation.start(h));deliver(nil,{error='worker_failed'})
assert(w.notices[1]:find('could not be confirmed',1,true),'worker failure was presented as safe to retry')
reset();h=host();assert(Generation.start(h));w.current=false;Generation.view_changed(h)
assert(not h.translation_generation_job and not h.busy_message and w.cancels==1,'navigation did not cancel worker')
w.current=true;deliver();assert(#w.notices==0 and w.downloads==0,'canceled worker delivered a result')
reset();h=host();assert(Generation.start(h));w.dismiss();assert(not h.translation_generation_job and w.cancels==1,'busy cancel did not stop worker')
reset();h=host();w.auth={cookies={}};w.merge_fail=true;assert(Generation.start(h));deliver()
assert(w.notices[1]:find('could not be confirmed',1,true),'session merge failure was presented as safe')
reset();h=host();w.native=false;assert(not Generation.start(h) and w.notices[1]:find('E-Ink login',1,true),'missing native grant not explained')
reset();h=host();w.offline=true;assert(not Generation.start(h) and w.offline_notice and #w.jobs==0,'offline request launched')
reset();h=host();w.start_failed=true;assert(not Generation.start(h) and not h.busy_message,'failed worker left busy state')
print('PASS: native translation request UI, cancellation and download handoff')
