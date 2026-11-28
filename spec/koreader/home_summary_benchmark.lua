require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Stats=require('weread.lib.read_stats')
local Profile=require('weread.lib.profile')
local now=os.time();local current=Stats.period_start('monthly',now)
local months={}
for i=0,23 do
    local base=Stats.shift_period('monthly',current,-i)
    local ending=Stats.shift_period('monthly',base,1)
    local daily={}
    for stamp=base,ending-86400,86400 do
        if arg[1]=='long' or stamp>=Profile.day(now)-3*86400 then daily[tostring(stamp)]=600 end
    end
    months[tostring(base)]={daily=daily,total=18000}
end
local settings={data_dir=home,get=function(_,key,default)
    if key=='account' then return {user_vid='900000'} end
    return default
end}
local db=require('weread.lib.library_db'):new(settings)
assert(db:putProfileState('statistics',{months=months,fetched_at=now}))
assert(db:putProfileState('goal',{minutes=30}))
local module=require('weread.ui.home_settings')
local host={library_db=db}
local opens,formats=0,0
local open_read=db.openRead
db.openRead=function(self,...) opens=opens+1;return open_read(self,...) end
local format=Stats.cst_fmt
Stats.cst_fmt=function(...) formats=formats+1;return format(...) end
local socket=require('socket')
collectgarbage('collect');local started,wall=os.clock(),socket.gettime()
local expected
for _=1,100 do
    local value=module.homeReadingSummary(host)
    assert(type(value)=='string' and value~='')
    if expected then assert(value==expected,'summary changed without a data update') else expected=value end
end
local seconds,elapsed=os.clock()-started,socket.gettime()-wall
local captured_opens,captured_formats=opens,formats
assert(db:putProfileState('goal',{minutes=45}))
local updated=module.homeReadingSummary(host)
assert(updated~=expected,'changed goal was not reflected immediately')
print('\nWEREAD_HOME_SUMMARY_BENCHMARK='..require('json').encode({result='PASS',
    mode=arg[1],calls=100,read_opens=captured_opens,calendar_formats=captured_formats,
    seconds=seconds,wall_seconds=elapsed,summary=expected,goal_update_visible=true})..'\n')
