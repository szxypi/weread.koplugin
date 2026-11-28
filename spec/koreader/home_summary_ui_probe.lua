require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local Stats=require('weread.lib.read_stats')
local Profile=require('weread.lib.profile')
local Home=require('weread.ui.home_settings')
local View=require('weread.ui.library_view')
local prefs=require('weread.lib.home_layout').normalize(nil)
local account='900000'
local settings={data_dir=home,get=function(_,key,default)
    if key=='account' then return {user_vid=account} end
    return default
end}
local db=require('weread.lib.library_db'):new(settings)
local now=os.time();local base=Stats.period_start('monthly',now);local day=Profile.day(now)
local snapshot={months={[tostring(base)]={daily={[tostring(day)]=600},total=600}},fetched_at=now}
assert(db:putProfileState('statistics',snapshot) and db:putProfileState('goal',{minutes=30}))
local view=View.show({mode='books',portal=true,home_layout=prefs,title='Synthetic home',
    status_text='10:00',summary_text='initial',books={},actions={},navigation={},paged=true,cover_mode=false}, {})
UI:forceRePaint()
local host=setmetatable({library_db=db,shelf_view=view,homeStatusText=function() return '10:00' end},{__index=Home})
local reads=0;local open=db.openRead
db.openRead=function(self,...) reads=reads+1;return open(self,...) end
host:startHomeStatusTimer(view);UI:forceRePaint()
assert(reads==1 and view._summary_button.text:find('30',1,true),'initial summary did not load')
local function tick()
    local task=assert(host._home_status_task);UI:unschedule(task);task();UI:forceRePaint()
end
assert(db:putProfileState('goal',{minutes=45}));tick()
assert(reads==2 and view._summary_button.text:find('45',1,true),'updated goal did not appear')
local connection=assert(db:open())
local statement=connection:prepare("UPDATE profile_state SET payload='invalid json' WHERE name='statistics'")
statement:step();statement:close();connection:close();tick()
assert(reads==3 and view._summary_button.text~=nil and not view._summary_button.text:find('45',1,true),
    'corrupt statistics were displayed as valid')
account='900001'
assert(db:putProfileState('statistics',snapshot) and db:putProfileState('goal',{minutes=55}));tick()
assert(reads==4 and view._summary_button.text:find('55',1,true),'account change reused the old overview')
local stale=host._home_status_task;host:stopHomeStatusTimer();stale()
assert(reads==4 and not host._home_status_task,'stopped timer read again')
UI:close(view);UI:forceRePaint()
print('\nWEREAD_HOME_SUMMARY_UI='..require('json').encode({result='PASS',reads=reads,
    goal_change=true,corruption=true,account_change=true,timer_stop=true})..'\n')
