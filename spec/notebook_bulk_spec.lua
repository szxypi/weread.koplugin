package.path='./?.lua;'..package.path
local scheduled={};local UI={}
function UI:scheduleIn(_seconds,callback) scheduled[#scheduled+1]=callback end
function UI:unschedule(callback) for i=#scheduled,1,-1 do if scheduled[i]==callback then table.remove(scheduled,i) end end end
function UI:nextTick(callback) scheduled[#scheduled+1]=callback end
function UI:close(dialog) if dialog.onCloseWidget then dialog:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end,T=function(s,...)
    local args={...};return (s:gsub('%%(%d+)',function(i) return tostring(args[tonumber(i)] or '') end))
end} end
package.preload['weread.ui.download_dialog']=function() return {new=function(_,data)
    function data:show() end
    function data:reportProgress(n) self.progress=n end
    function data:setTitle(title) self.title=title end
    return data
end} end
local revision='a';local saved={};local displayed={};local fail_save=false;local renewal_callback
package.loaded['weread.ui.personal_marks']={changed=function(_,value) displayed[#displayed+1]=value.id end}
local marks={display_id=function(id) return type(id)=='string' and id:match('^%d+$') and id or nil end,
    capture=function() return {revision=revision,native={scope={},revision=1}} end,
    matches=function(_,access) return access.revision==revision end,
    validate=function(_,value,id) assert(value.id==id and value.kind=='marks');return value end,
    fetch=function(_,id) return {id=id,kind='marks'} end}
local thoughts={validate=function(_,value,id) assert(value.id==id and value.kind=='thoughts');return value end,
    fetch=function(_,id) return {id=id,kind='thoughts'} end,EXPIRED='expired'}
package.loaded['weread.lib.my_cloud_marks']=marks
package.loaded['weread.lib.my_cloud_thoughts']=thoughts
package.loaded['weread.lib.my_cloud_marks_store']={MAX_BOOKS=64,MAX_PAYLOAD=4*1024*1024,new=function(_,_,_,variant)
    return {write=function(_,value,options)
        assert(options.preserve_existing==true)
        if fail_save then return false end
        saved[#saved+1]={value=value,variant=variant};return true
    end}
end}
package.loaded['weread.lib.native_read_recovery']={cancel=function(_,job) job.renewal_cancelled=true end,
    current=function() return true end,start=function(_,job,_,options)
        if job.recovery_attempted then return false end
        job.recovery_attempted=true;job.renewing=true;renewal_callback=function(success)
            job.renewing=false
            if options.is_current() then options.complete(success,{revision=revision,native={scope={},revision=3}})
            else options.stale() end
        end
        return true
    end}
local tasks,cancels
package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_,task,callback)
    tasks[#tasks+1]={task=task,callback=callback};return true
end,cancel=function() cancels=cancels+1 end} end}
local Bulk=require('weread.ui.notebook_bulk')
local function fixture()
    scheduled={};saved={};displayed={};tasks={};cancels=0;fail_save=false;revision='a';renewal_callback=nil
    local state={current=true,online=true,account='a',notices={}}
    local db={accountKey=function() return state.account end}
    local host={settings={data_dir='/tmp/data',cache_dir='/tmp/cache'},client={},library_db=db,
        isNetworkOnline=function() return state.online end,showOffline=function(_,s) state.notices[#state.notices+1]=s end,
        showInfo=function(_,s) state.notices[#state.notices+1]=s end,
        showTransientInfo=function(_,s) state.notices[#state.notices+1]=s end}
    local owner={account='a',menu={},value={books={{bookId='1'},{bookId='2'},{bookId='unsupported'}}}}
    local function current() return state.current end
    return host,owner,state,current
end
local function step()
    local callback=assert(table.remove(scheduled,1));callback()
end
local function complete(index) local task=assert(tasks[index]);task.callback(task.task()) end
local host,owner,state,current=fixture()
assert(Bulk.start(host,owner,current) and #tasks==1)
local job=owner.bulk_context;assert(job.skipped==1 and job.dialog.progress_max==4)
complete(1);step();complete(2);step();complete(3);step();complete(4)
assert(#saved==4 and saved[1].value.kind=='marks' and saved[2].variant=='thoughts'
    and saved[3].value.id=='2' and not owner.bulk_context and state.notices[1]:find('4/4',1,true))
assert(#displayed==2 and displayed[1]=='1' and displayed[2]=='2','saved marks did not refresh the open reader')
tasks[4].callback(tasks[4].task());assert(#saved==4,'duplicate completion saved again')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));complete(1)
owner.bulk_context.dialog.buttons[1][1].callback()
assert(#saved==1 and #scheduled==0 and not owner.bulk_context and state.notices[1]:find('cancelled',1,true))
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));local stale=tasks[1]
state.account='b';stale.callback(stale.task())
assert(#saved==0 and not owner.bulk_context and #state.notices==0,'changed account accepted data')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));local active=owner.bulk_context.dialog
UI:close(active);assert(not owner.bulk_context and cancels>0 and #state.notices==0,'closing the dialog left work running')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));fail_save=true;complete(1)
assert(#saved==0 and not owner.bulk_context and state.notices[1]:find('stopped',1,true))
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));tasks[1].callback({ok=true,value={id='2',kind='marks'}})
assert(#saved==0 and not owner.bulk_context and #state.notices==1,'foreign response was saved')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));tasks[1].callback({native_expired=true})
assert(renewal_callback and owner.bulk_context);revision='b';renewal_callback(true);step();complete(2)
assert(#saved==1 and saved[1].value.id=='1' and #state.notices==0,'renewal did not retry only the failed set')
step();tasks[3].callback({native_expired=true});assert(not owner.bulk_context and #state.notices==1,
    'repeated expiry started another renewal')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));tasks[1].callback({native_expired=true})
local pending=renewal_callback;owner.bulk_context.dialog.buttons[1][1].callback();pending(true)
assert(not owner.bulk_context and #scheduled==0 and #tasks==1 and #state.notices==1,
    'cancelled renewal resumed the batch')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));owner.value={books={}}
tasks[1].callback(tasks[1].task());assert(#saved==0 and not owner.bulk_context and #state.notices==0,
    'replaced notebook list accepted an old response')
host,owner,state,current=fixture();state.online=false
assert(not Bulk.start(host,owner,current) and #tasks==0 and #state.notices==1)
host,owner,state,current=fixture();owner.value.books={};for i=1,65 do owner.value.books[i]={bookId=tostring(i)} end
assert(Bulk.start(host,owner,current) and #owner.bulk_context.ids==64 and owner.bulk_context.skipped==1 and #state.notices==0)
Bulk.cancel(host,owner)
package.loaded['weread.lib.my_cloud_marks_store'].MAX_BOOKS=5000
host,owner,state,current=fixture();owner.value.books={};for i=1,130 do owner.value.books[i]={bookId=tostring(i)} end
assert(Bulk.start(host,owner,current) and #owner.bulk_context.ids==130 and owner.bulk_context.skipped==0 and #state.notices==0,
    'large notebook list stopped at the old 64-book limit')
Bulk.cancel(host,owner)
host,owner,state,current=fixture();owner.value.books={};for i=1,5001 do owner.value.books[i]={bookId=tostring(i)} end
assert(Bulk.start(host,owner,current) and #owner.bulk_context.ids==5000 and owner.bulk_context.skipped==1
    and owner.bulk_context.dialog.progress_max==10000 and #state.notices==0,'maximum catalog bound changed')
Bulk.cancel(host,owner)
print('PASS: bulk notebook caching, quota protection, cancellation and ownership')
