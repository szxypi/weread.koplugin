package.path='./?.lua;'..package.path
local shown,closed={},{}
package.preload['ui/uimanager']=function() return {
    show=function(_self,value) shown[#shown+1]=value end,
    close=function(_self,value) closed[#closed+1]=value end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,
    T=function(text,...) local args={...};return (text:gsub('%%(%d+)',function(index) return tostring(args[tonumber(index)]) end)) end} end
local Export=require('weread.ui.notes_export')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local state={account='guest',outputs={},jobs={},aborts=0,worker_cancels=0,notices={}}
    local host={settings={data_dir='/synthetic'},_reader_session_gen=1,
        library_db={accountKey=function() return state.account end},client={json_encode=function() return '{}' end},
        ui={document={file='/synthetic/book.epub'},doc_props={title='Test'},annotation={annotations={{drawer='lighten',text='Synthetic'}}}},
        showInfo=function(_self,value) state.notices[#state.notices+1]=value end,
        showBusy=function(self,_value,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        closeWeReadUI=function(self) Export.cancel(self) end,
        create_notes_output=function(directory,title,format)
            state.created={directory=directory,title=title,format=format}
            if state.create_failed then return nil end
            local output={path='/synthetic/export.md',bytes=0}
            function output:write(value) self.bytes=self.bytes+#value;return not state.write_failed end
            function output:sync() return not state.sync_failed end
            function output:accept(bytes) if state.accept_error then error('private path failure') end;return not state.accept_failed and bytes==self.bytes end
            function output:abort() state.aborts=state.aborts+1;self.path=nil end
            state.outputs[#state.outputs+1]=output;return output
        end,
        notes_export_worker={start=function(_self,task,callback)
            if state.start_error then error('private failure') end
            if state.start_failed then return false end
            state.jobs[#state.jobs+1]={task=task,callback=callback};return true
        end,cancel=function() state.worker_cancels=state.worker_cancels+1 end}}
    local function deliver(index,result)
        local job=state.jobs[index or #state.jobs]
        if result==nil then result=job.task() end
        job.callback(result)
    end
    return host,state,deliver
end
local host,state,deliver=fixture()
expect(Export.start(host,'markdown') and state.created.directory=='/synthetic/exports/notes','guest/offline export did not start')
deliver()
expect(not host.notes_export_job and not host.busy_message and state.aborts==0 and state.outputs[1].path,'successful file removed or busy retained')
expect(state.notices[1]:find('1 local notes',1,true),'success count missing')
for _,change in ipairs({'account','session','file','document','deadline'}) do
    host,state,deliver=fixture();Export.start(host,'json')
    if change=='account' then state.account='other'
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='file' then host.ui.document.file='/other'
    elseif change=='document' then host.ui.document={file='/synthetic/book.epub'}
    else host.notes_export_job.started=os.time()-121 end
    deliver()
    expect(state.aborts==1 and not host.busy_message and #state.notices==0,change..' retained stale output')
end
host,state,deliver=fixture();Export.start(host,'json');state.dismiss()
expect(state.aborts==1 and not host.notes_export_job,'dismiss did not remove incomplete file')
Export.start(host,'markdown');local busy=host.busy_message;deliver(1)
expect(host.notes_export_job and host.busy_message==busy and #state.notices==0,'old callback canceled new job')
deliver(2);expect(#state.notices==1 and state.aborts==1,'new job did not complete independently')
for _,failure in ipairs({'write_failed','sync_failed','accept_failed','accept_error','start_failed','start_error'}) do
    host,state,deliver=fixture();state[failure]=true
    local started=Export.start(host,'json')
    if started then deliver() end
    expect(state.aborts==1 and not host.notes_export_job and not host.busy_message and #state.notices==1,failure..' did not clean up')
    expect(not state.notices[1]:find('private',1,true),failure..' leaked raw exception')
end
host,state,deliver=fixture();Export.start(host,'json');deliver(nil,{ok=true,count=1,bytes=1.5})
expect(state.aborts==1,'fractional byte count accepted')
host,state,deliver=fixture();host.ui.annotation.annotations={{text='bookmark'}};Export.start(host,'json');deliver()
expect(state.aborts==1 and state.notices[1]:find('no local',1,true),'plain bookmark exported or partial file left')
host,state=fixture();state.create_failed=true
expect(not Export.start(host,'json') and #state.jobs==0 and #state.notices==1,'create failure started work')
host,state=fixture();host.ui.annotation.annotations={}
expect(not Export.start(host,'json') and #state.outputs==0,'empty annotation list created a file')
host,state=fixture();Export.show(host);local picker=host._notes_export_picker
expect(picker and picker.keep_dialog_open,'format picker missing')
state.account='changed';picker.ok_callback()
expect(not host._notes_export_picker and #state.jobs==0,'stale picker exported after account change')
Export.show(host);local old=host._notes_export_picker;Export.show(host);old.other_buttons[1][1].callback()
expect(host._notes_export_picker~=nil and #state.jobs==0,'old picker closed or started replacement')
Export.cancel(host);expect(not host._notes_export_picker,'cancel retained picker')
print('PASS: local notes export UI ('..checks..' checks)')
