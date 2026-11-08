package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
local Catalog=require('weread.lib.category_catalog')
local UI=require('weread.ui.category_catalog')
local source={data={{CategoryId='100',title='Literature'}}}
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    local state={account=nil,jobs={},notices={},writes=0,cancels=0,online=true}
    local host={settings={},client={get_store_categories=function() return source end},
        library_db={accountKey=function() return state.account end},
        isNetworkOnline=function() return state.online end,
        runOnlineTask=function(_self,_label,callback) state.scheduled=callback;return not state.offline_schedule end,
        showBusy=function(self,_label,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_self,text) state.notices[#state.notices+1]=text end,
        showTransientInfo=function(_self,text) state.notices[#state.notices+1]=text end,
        showDiscoveryCategoryPicker=function(_self,value) state.shown=value end,
        category_catalog_store={read=function() return state.saved end,
            write=function(_self,value) state.writes=state.writes+1;if state.write_error then error('private storage path') end
                if state.write_failed then return false end;state.saved=value;return true end},
        category_catalog_worker={start=function(_self,task,callback)
            if state.start_error then error('private spawn failure') end
            if state.start_failed then return false end
            state.jobs[#state.jobs+1]={task=task,callback=callback};return true
        end,cancel=function() state.cancels=state.cancels+1 end}}
    local function deliver(index,result)
        local job=state.jobs[index or #state.jobs]
        if not result then result=job.task() end
        job.callback(result)
    end
    return host,state,deliver
end
local host,state,deliver=fixture()
expect(UI.open(host) and host.discovery_loading and #state.jobs==0,'public load bypassed scheduling or needed auth')
state.scheduled();expect(#state.jobs==1 and not state.shown,'network ran before worker boundary')
deliver();expect(state.shown and state.saved and state.writes==1 and not host.busy_message and not host.discovery_loading,'success did not save/show/clean up')
state.shown=nil;host.discovery_categories=nil;state.online=false
expect(UI.open(host) and state.shown.categories[1].id=='100' and #state.jobs==1,'offline reopen did not use persisted public cache')
expect(not UI.open(host,true) and #state.notices==1 and state.shown,'offline refresh dropped saved choices')
host.discovery_categories={invalid=true};state.shown=nil
expect(UI.open(host) and state.shown.categories[1].id=='100','invalid in-memory cache prevented valid persisted fallback')
for _,change in ipairs({'account','epoch','session','deadline'}) do
    host,state,deliver=fixture();UI.open(host);state.scheduled()
    if change=='account' then state.account='other'
    elseif change=='epoch' then host.discovery_epoch=1
    elseif change=='session' then host._reader_session_gen=1
    else host.category_catalog_request.started=os.time()-121 end
    deliver()
    expect(not state.shown and state.writes==0 and not host.busy_message and #state.notices==0,change..' accepted stale result')
end
host,state=fixture();UI.open(host);host.discovery_epoch=1;state.scheduled()
expect(#state.jobs==0 and not host.discovery_loading,'closed view still launched network worker')
host,state,deliver=fixture();UI.open(host);state.scheduled();local old_dismiss=state.dismiss;old_dismiss()
UI.open(host);state.scheduled();local busy=host.busy_message;old_dismiss();deliver(1)
expect(host.category_catalog_request and host.busy_message==busy and state.writes==0,'old cancel/result canceled replacement')
deliver(2);expect(state.writes==1 and state.shown~=nil,'replacement load did not complete')
for _,failure in ipairs({'start_failed','start_error'}) do
    host,state=fixture();state[failure]=true;UI.open(host);state.scheduled()
    expect(not host.discovery_loading and not host.busy_message and #state.notices==1,failure..' leaked lock/dialog')
    expect(not state.notices[1]:find('private',1,true),failure..' exposed exception')
end
for _,failure in ipairs({'write_failed','write_error'}) do
    host,state,deliver=fixture();state[failure]=true;UI.open(host);state.scheduled();deliver()
    expect(state.shown~=nil and not state.saved and #state.notices==1,failure..' discarded usable current list or claimed offline save')
end
host,state,deliver=fixture();state.saved=Catalog.project(source)
local saved=state.saved;UI.open(host,true);state.scheduled();deliver(nil,{ok=true,catalog={}})
expect(state.saved==saved and state.writes==0 and state.shown.categories[1].id=='100' and #state.notices==1,'invalid refresh replaced persisted cache or lost choices')
host,state=fixture();state.online=false
expect(not UI.open(host) and not state.shown and #state.notices==1,'guest offline state launched or invented categories')
host,state=fixture();state.offline_schedule=true
expect(not UI.open(host) and not host.discovery_loading and not host.busy_message,'failed schedule retained loading state')
host,state=fixture();UI.open(host);state.scheduled();host.discovery_request_context={};UI.cancel(host)
expect(host.discovery_loading,'category cancellation cleared another bookstore request lock')
print('PASS: public category UI ('..checks..' checks)')
