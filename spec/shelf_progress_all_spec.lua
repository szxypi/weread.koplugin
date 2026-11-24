package.path='./?.lua;'..package.path
local scheduled={}
local UI={}
function UI:scheduleIn(_delay,callback) scheduled[#scheduled+1]=callback end
function UI:unschedule(callback) for i=#scheduled,1,-1 do if scheduled[i]==callback then table.remove(scheduled,i) end end end
function UI:nextTick(callback) scheduled[#scheduled+1]=callback end
function UI:show() end
function UI:close(dialog) if dialog.onCloseWidget then dialog:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,T=function(value,...)
    local args={...};return (value:gsub('%%(%d+)',function(i) return tostring(args[tonumber(i)] or '') end))
end} end
package.preload['weread.ui.download_dialog']=function() return {new=function(_,value)
    function value:show() UI:show(self) end
    function value:reportProgress(n) self.progress=n end
    function value:setTitle(title) self.title=title end
    return value
end} end
local revision='a';local sent={};local sleeps=0
package.loaded['weread.lib.shelf_progress']={
    selection=function() return {revision=revision,web={kind='web'}} end,
    matches=function(_,access) return access.revision==revision end,
    supports=function(id) return id and id:match('^%d+$')~=nil end,
    fetch=function(_,ids,ctx,access,options)
        sent[#sent+1]={ids=ids,revision=access.revision,web_only=options.web_only}
        local result={}
        for i,id in ipairs(ids) do
            ctx.checkCancelled();ctx.emit{current=i,total=#ids}
            result[#result+1]={book_id=id,percent=i,fetched_at=1000,source='web'}
        end
        return {snapshots=result}
    end,
}
local Bulk=require('weread.ui.shelf_progress_all')
local function fixture(count)
    scheduled={};sent={};sleeps=0;revision='a'
    local state={account='a',online=true,current=true,notices={},saves={},tasks={},cancelled=0,redraws=0}
    local worker={available=function() return true end,start=function(_,options)
        local request={options=options};state.tasks[#state.tasks+1]=request;return true,request
    end,cancel=function() state.cancelled=state.cancelled+1 end}
    local db={accountKey=function() return state.account end,putShelfProgress=function(_,values)
        state.saves[#state.saves+1]=values;return not state.fail_save
    end}
    local host={library_db=db,settings={cache_dir='/synthetic',data_dir='/synthetic',get=function(_,_,default) return default end},
        client={},shelf_regular={},shelf_progress_all_worker=worker}
    for i=1,count do host.shelf_regular[i]={bookId=tostring(900000+i)} end
    function host:isNetworkOnline() return state.online end
    function host:closeBusy() self.busy_message=nil end
    function host:showInfo(text) state.notices[#state.notices+1]=text end
    function host:showTransientInfo(text) state.notices[#state.notices+1]=text end
    function host:cancelShelfProgress() Bulk.cancel(self);state.visible_cancelled=true end
    local origin={owner={},is_current=function() return state.current end}
    local function done(options) state.redraws=state.redraws+1;state.redraw_options=options end
    return host,origin,state,done
end
local function run_task(request)
    return request.options.task{checkCancelled=function() end,emit=function(state)
        if request.options.on_progress then request.options.on_progress(state) end
    end,sleep=function(seconds) assert(seconds==0.25);sleeps=sleeps+1 end}
end
local function next_scheduled() local task=assert(table.remove(scheduled,1));task() end
local host,origin,state,done=fixture(13)
assert(Bulk.start(host,origin,done) and state.visible_cancelled and #state.tasks==1)
local first=state.tasks[1];first.options.on_done{ok=true,value=run_task(first)}
assert(#state.saves==1 and #state.saves[1]==5 and sleeps==4 and #scheduled==1)
next_scheduled();local second=state.tasks[2];second.options.on_done{ok=true,value=run_task(second)}
next_scheduled();local third=state.tasks[3];third.options.on_done{ok=true,value=run_task(third)}
assert(#state.saves==3 and #state.saves[3]==3 and #sent==3 and sleeps==10
    and state.redraws==1 and state.redraw_options.skip_progress_fetch_once
    and not host.shelf_progress_all_context and not host.busy_message
    and state.notices[1]:find('13/13',1,true),'complete refresh failed')
third.options.on_done{ok=true,value=run_task(third)};assert(#state.saves==3,'duplicate callback wrote again')
host,origin,state,done=fixture(8);assert(Bulk.start(host,origin,done));first=state.tasks[1]
first.options.on_done{ok=true,value=run_task(first)}
local dialog=host.busy_message;dialog.buttons[1][1].callback()
assert(#state.saves==1 and state.redraws==1 and state.redraw_options.skip_progress_fetch_once
    and #scheduled==0 and not host.shelf_progress_all_context
    and state.notices[1]:find('cancelled',1,true),'cancel did not preserve completed batch')
host,origin,state,done=fixture(8);assert(Bulk.start(host,origin,done));first=state.tasks[1]
state.account='b';first.options.on_done{ok=true,value=run_task(first)}
assert(#state.saves==0 and state.redraws==0 and not host.shelf_progress_all_context,'foreign account received data')
host,origin,state,done=fixture(8);assert(Bulk.start(host,origin,done));first=state.tasks[1]
host.settings.data_dir='/changed';first.options.on_done{ok=true,value=run_task(first)}
assert(#state.saves==0 and state.redraws==0 and not host.shelf_progress_all_context,'changed storage received stale data')
host,origin,state,done=fixture(8);assert(Bulk.start(host,origin,done));dialog=host.busy_message
UI:close(dialog)
assert(state.cancelled==1 and not host.shelf_progress_all_context and not origin.owner._shelf_popup,
    'external dialog close failed to cancel the worker')
host,origin,state,done=fixture(8);assert(Bulk.start(host,origin,done));first=state.tasks[1]
first.options.on_done{ok=true,value={snapshots={{book_id='900002',percent=5,fetched_at=1000,source='web'}}}}
assert(#state.saves==0 and state.redraws==1 and state.notices[1]:find('stopped',1,true),
    'mismatched response was saved')
for _,snapshot in ipairs({
    {book_id='900001',percent=0,exact_percent=1,fetched_at=1000,source='web'},
    {book_id='900001',percent=0,exact_percent=0/0,fetched_at=1000,source='web'},
    {book_id='900001',unavailable=true,exact_percent=0,fetched_at=1000,source='web'},
}) do
    host,origin,state,done=fixture(1);assert(Bulk.start(host,origin,done));first=state.tasks[1]
    first.options.on_done{ok=true,value={snapshots={snapshot}}}
    assert(#state.saves==0 and state.notices[1]:find('stopped',1,true),'invalid exact progress was persisted')
end
host,origin,state,done=fixture(1);assert(Bulk.start(host,origin,done));first=state.tasks[1]
first.options.on_done{ok=true,value={snapshots={{book_id='900001',percent=0,exact_percent=0.3,fetched_at=1000,source='web'}}}}
assert(#state.saves==1 and state.saves[1][1].exact_percent==0.3,'fractional bulk progress was rejected')
host,origin,state,done=fixture(8);assert(Bulk.start(host,origin,done));first=state.tasks[1]
first.options.on_done{ok=true,value={snapshots={
    [1]={book_id='900001',percent=5,fetched_at=1000,source='web'},
    [3]={book_id='900003',percent=5,fetched_at=1000,source='web'},
},failed=true}}
assert(#state.saves==0 and state.redraws==1 and state.notices[1]:find('stopped',1,true),
    'sparse response was saved')
host,origin,state,done=fixture(8);state.fail_save=true;assert(Bulk.start(host,origin,done));first=state.tasks[1]
first.options.on_done{ok=true,value=run_task(first)}
assert(#state.saves==1 and state.redraws==1 and not host.shelf_progress_all_context
    and state.notices[1]:find('0/8',1,true),'failed storage counted unsaved data')
host,origin,state,done=fixture(2);host.library_db.putShelfProgress=function() error('storage failure') end
assert(Bulk.start(host,origin,done));first=state.tasks[1];first.options.on_done{ok=true,value=run_task(first)}
assert(state.redraws==1 and not host.shelf_progress_all_context and state.notices[1]:find('0/2',1,true),
    'storage exception left the update active')
host,origin,state,done=fixture(8);assert(Bulk.start(host,origin,done));first=state.tasks[1]
local partial={snapshots={{book_id='900001',percent=4,fetched_at=1000,source='web'}},failed=true}
first.options.on_done{ok=true,value=partial}
assert(#state.saves==1 and #state.saves[1]==1 and state.notices[1]:find('1/8',1,true),
    'failure did not retain only the valid prefix')
assert(host.shelf_progress_retry_at>os.time() and host.shelf_progress_retry_revision=='a'
    and state.redraw_options.skip_progress_fetch_once,'failure immediately allowed another visible request')
host,origin,state,done=fixture(2);state.online=false
assert(not Bulk.start(host,origin,done) and #state.tasks==0 and #state.notices==1,'offline refresh started')
host,origin,state,done=fixture(2);state.account=nil
assert(not Bulk.start(host,origin,done) and #state.tasks==0 and #state.notices==1,'signed-out refresh started')
host,origin,state,done=fixture(2);host.shelf_regular.extra={bookId='900009'}
assert(not Bulk.start(host,origin,done) and #state.tasks==0,'malformed shelf started a partial refresh')
host,origin,state,done=fixture(2)
host.shelf_regular[3]={bookId='CB_without_web'};host.shelf_regular[4]={bookId='900001'}
assert(Bulk.start(host,origin,done));first=state.tasks[1];first.options.on_done{ok=true,value=run_task(first)}
assert(#state.saves[1]==2 and state.notices[1]:find('2/2 books saved; 2 skipped',1,true),
    'unsupported or duplicate books were sent')
local renewal_callback
package.loaded['weread.ui.web_renewal']={run=function(_,_,callback) renewal_callback=callback;return true,{} end,
    cancel=function() end}
host,origin,state,done=fixture(7);assert(Bulk.start(host,origin,done));first=state.tasks[1]
first.options.on_done{ok=true,value={snapshots={{book_id='900001',percent=4,fetched_at=1000,source='web'}},
    failed=true,web_expired=true,next_index=2}}
assert(#state.saves==1 and renewal_callback and #state.tasks==1)
revision='b';renewal_callback(true);next_scheduled();second=state.tasks[2]
second.options.on_done{ok=true,value=run_task(second)};next_scheduled();third=state.tasks[3]
third.options.on_done{ok=true,value=run_task(third)}
assert(sent[1].ids[1]=='900002' and sent[1].revision=='b' and sent[1].web_only
    and #state.saves==3 and state.notices[1]:find('7/7',1,true),'renewal repeated prefix or lost suffix')
local renewal_cancelled=0
package.loaded['weread.ui.web_renewal']={run=function(_,_,callback) renewal_callback=callback;return true,{} end,
    cancel=function() renewal_cancelled=renewal_cancelled+1 end}
host,origin,state,done=fixture(7);assert(Bulk.start(host,origin,done));first=state.tasks[1]
first.options.on_done{ok=true,value={snapshots={{book_id='900001',percent=4,fetched_at=1000,source='web'}},
    failed=true,web_expired=true,next_index=2}}
host.busy_message.buttons[1][1].callback();renewal_callback(true)
assert(renewal_cancelled==1 and not host.shelf_progress_all_context and #scheduled==0 and #state.tasks==1,
    'cancelled renewal resumed the old update')
print('PASS: bulk shelf progress batching, cancellation, ownership, failures and one renewal')
