package.path='./?.lua;'..package.path
local UI={}
function UI:show(widget) self.top=widget end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
function UI:nextTick(fn) fn() end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,
    T=function(text,...)
        local values={...};return (text:gsub('%%(%d+)',function(i) return tostring(values[tonumber(i)]) end))
    end} end
local Model=require('weread.lib.cloud_notes_export')
local Store=require('weread.lib.my_cloud_marks_store')
local Export=require('weread.ui.cloud_notes_export')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local marks={schema=1,book_id='41',updated={{bookmarkId='m',type=1}},chapters={},fetched_at=1000}
local thoughts={schema=1,book_id='41',reviews={{reviewId='t',content='synthetic'}},fetched_at=1001}
local function fixture(view_thoughts,missing)
    local state={account='owner',scope=true,notices={},outputs={},jobs={}}
    if not missing then state.other=view_thoughts and marks or thoughts end
    local host={client={},settings={data_dir='/synthetic'},library_db={accountKey=function() return state.account end}}
    function host.settings:get_book() return {title='Synthetic book',author='Synthetic author'} end
    function host:showInfo(value) state.notices[#state.notices+1]=value end
    function host:showBusy(_text,cancel) self.busy_message={cancel=cancel} end
    function host:closeBusy() self.busy_message=nil end
    function host.create_notes_output(_dir,_title,_format)
        if state.create_fail then return nil end
        local output={path='/synthetic/export.md',contents='',aborted=false}
        function output:write(value) self.contents=self.contents..value;return not state.write_fail end
        function output:sync() return not state.sync_fail end
        function output:accept(bytes) return not state.accept_fail and bytes==#self.contents end
        function output:abort() self.aborted=true end
        state.outputs[#state.outputs+1]=output;return output
    end
    local owner={id='41',thoughts=view_thoughts,value=view_thoughts and thoughts or marks,menu={}}
    local function current(_host,value) return value==owner and state.scope and state.account=='owner' end
    Store.new=function(_self,_library,_client,variant)
        state.variant=variant
        return {read=function() return state.other end}
    end
    package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_self,task,callback)
        if state.start_fail then return false end
        state.jobs[#state.jobs+1]={task=task,callback=callback};return true
    end,cancel=function() state.cancelled=true end} end}
    function state:deliver(index,result)
        local job=self.jobs[index or #self.jobs];job.callback(result or job.task())
    end
    return host,owner,state,current
end
local original=Model.write
local expected_marks,expected_thoughts=marks,thoughts
Model.write=function(input,format,_codec,sink)
    assert(input.book_id=='41' and (format=='json' or format=='markdown'))
    assert(input.marks==expected_marks and input.thoughts==expected_thoughts)
    if not sink('synthetic export') then error('synthetic write') end
    return {ok=true,count=2,bytes=#'synthetic export'}
end
local host,owner,state,current=fixture(false)
expect(Export.show(host,owner,current) and state.variant=='thoughts','marks view did not load the saved thoughts snapshot')
expect(UI.top.text:find('Marks: 1',1,true) and UI.top.text:find('Thoughts: 1',1,true),'snapshot coverage was not shown')
UI.top.other_buttons[1][1].callback()
expect(owner.export_job and host.busy_message and #state.jobs==1,'Markdown export did not start in a worker')
state:deliver()
expect(not owner.export_job and not state.outputs[1].aborted and state.outputs[1].contents=='synthetic export'
    and state.notices[1]:find('2 saved cloud notes',1,true),'successful export did not retain its file')
host,owner,state,current=fixture(true)
expect(Export.show(host,owner,current) and state.variant==nil,'thought view did not read the saved marks snapshot')
UI.top.ok_callback();state:deliver()
expect(not state.outputs[1].aborted,'JSON export was removed')
host,owner,state,current=fixture(false,true)
expect(state.other==nil and Export.show(host,owner,current) and UI.top.text:find('Thoughts: Not saved or unavailable',1,true),
    'missing saved thought data was presented as complete')
expected_thoughts=nil;UI.top.ok_callback();state:deliver();expected_thoughts=thoughts
expect(not state.outputs[1].aborted,'available saved marks could not be exported alone')
host,owner,state,current=fixture(false,true);owner.value={updated={}}
expect(not Export.show(host,owner,current) and #state.outputs==0 and #state.notices==1,
    'an empty partial snapshot started an export')
for _i,change in ipairs({'account','value','cancel','sync','accept','start'}) do
    host,owner,state,current=fixture(false);Export.show(host,owner,current)
    if change=='start' then state.start_fail=true end
    UI.top.ok_callback()
    if change=='account' then state.account='other' elseif change=='value' then owner.value={} elseif change=='cancel' then host.busy_message.cancel()
    elseif change=='sync' then state.sync_fail=true elseif change=='accept' then state.accept_fail=true end
    if change~='start' then state:deliver() end
    expect(state.outputs[1].aborted and not owner.export_job,change..' retained an incomplete output')
end
host,owner,state,current=fixture(false);Export.show(host,owner,current)
local stale=UI.top;state.account='other';stale.ok_callback()
expect(#state.jobs==0 and #state.outputs==0,'stale popup exported another account')
Export.cancel(host,owner)
host,owner,state,current=fixture(false);host.settings.get_book=function() error('synthetic private error') end
expect(not Export.show(host,owner,current) and #state.outputs==0 and #state.notices==1
    and not state.notices[1]:find('private error',1,true),'book read failure leaked or started an export')
host,owner,state,current=fixture(false);Export.show(host,owner,current);UI.top.ok_callback()
state:deliver(nil,{ok=true,count=2,bytes=1.5})
expect(state.outputs[1].aborted and not owner.export_job,'invalid worker result kept a partial output')
host,owner,state,current=fixture(false);Export.show(host,owner,current);UI.top.ok_callback()
host.busy_message.cancel();Export.show(host,owner,current);UI.top.ok_callback();local newer=owner.export_job
state:deliver(1)
expect(owner.export_job==newer and state.outputs[1].aborted,'old completion interfered with a newer export')
state:deliver(2);expect(not owner.export_job and not state.outputs[2].aborted,'newer export did not complete')
Model.write=original
print('cloud_notes_export_ui_spec: '..checks..' checks')
