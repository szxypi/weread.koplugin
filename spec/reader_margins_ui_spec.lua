package.path='./?.lua;'..package.path
local tasks,removed={},{}
package.preload['ui/uimanager']=function() return {
    show=function() end,close=function(_,view) if view.onCloseWidget then view:onCloseWidget() end end,
    scheduleIn=function(_,delay,fn) tasks[#tasks+1]={delay=delay,fn=fn} end,
    unschedule=function(_,fn) removed[fn]=true end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,args)
    function args:setTitle(value) self.title=value end
    return args
end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,args) return args end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,
    T=function(text,...) for i=1,select('#',...) do text=text:gsub('%%'..i,tostring(select(i,...))) end;return text end} end
local config={h_page_margins={10,20},t_page_margin=15,b_page_margin=25,sync_t_b_page_margins=0}
local counts={h=0,v=0};local fail_vertical=false
local typeset={configurable=config,unscaled_margins={10,15,20,25},sync_t_b_page_margins=false}
function typeset:onSetPageHorizMargins(value)
    counts.h=counts.h+1;self.unscaled_margins[1],self.unscaled_margins[3]=value[1],value[2]
end
function typeset:onSetPageTopAndBottomMargin(value)
    counts.v=counts.v+1;self.unscaled_margins[2],self.unscaled_margins[4]=value[1],value[2]
    if fail_vertical then fail_vertical=false;error('synthetic reflow failure') end
end
local doc={configurable=config};local ui={document=doc,typeset=typeset}
local host={ui=ui};local active=true;local message
function host:showInfo(value) message=value end
local Margins=require('weread.ui.reader_margins')
local function button(dialog,id)
    for _,row in ipairs(dialog.buttons) do for _,item in ipairs(row) do if item.id==id then return item end end end
    error('missing button '..id)
end
local function latest(delay)
    for i=#tasks,1,-1 do if tasks[i].delay==delay and not removed[tasks[i].fn] then return tasks[i].fn end end
    error('missing task')
end
local function open()
    assert(Margins.show(host,function() return active end))
    return host._weread_reader_margins,host._weread_reader_margins.dialog
end
local state,dialog=open()
assert(not state.pending)
button(dialog,'margin_horizontal_up').callback();local stale=latest(.4)
button(dialog,'margin_horizontal_up').callback();button(dialog,'margin_vertical_up').callback()
stale();assert(counts.h==0 and counts.v==0,'superseded adjustment applied')
latest(.4)();assert(counts.h==1 and counts.v==1)
assert(config.h_page_margins[1]==20 and config.h_page_margins[2]==30
    and config.t_page_margin==20 and config.b_page_margin==30 and config.sync_t_b_page_margins==0)
button(dialog,'margin_standard').callback();latest(.4)()
assert(config.h_page_margins[1]==10 and config.h_page_margins[2]==10
    and config.t_page_margin==15 and config.b_page_margin==15)
button(dialog,'margin_horizontal_up').callback();config.h_page_margins={25,25}
typeset.unscaled_margins[1],typeset.unscaled_margins[3]=25,25
latest(.4)();assert(config.h_page_margins[1]==25 and message=='Page margins changed. Please try again.')
button(dialog,'margin_wide').callback();fail_vertical=true;latest(.4)()
assert(config.h_page_margins[1]==25 and config.h_page_margins[2]==25
    and config.t_page_margin==15 and config.b_page_margin==15 and message=='Could not apply page margins.',
    'partial reflow failure did not restore the previous margins')
button(dialog,'margin_vertical_up').callback();local pending=latest(.4);Margins.cancel(host);pending()
assert(config.t_page_margin==15,'canceled adjustment applied')
state,dialog=open();button(dialog,'margin_horizontal_up').callback();assert(state.pending);pending=latest(.4)
active=false;pending();active=true;assert(not host._weread_reader_margins and config.h_page_margins[1]==25)
local defaults={copt_t_page_margin=9,copt_h_page_margins={1,2}}
local fail_read,fail_write=false,false
G_reader_settings={readSetting=function(_,key) if fail_read and key=='copt_b_page_margin' then error('failed') end;return defaults[key] end,
    saveSetting=function(_,key,value) if fail_write and key=='copt_b_page_margin' then fail_write=false;error('failed') end;defaults[key]=value end,
    delSetting=function(_,key) defaults[key]=nil end,flush=function(self) return self end}
state,dialog=open();button(dialog,'margin_default').callback();local confirm=state.confirm
assert(confirm and defaults.copt_t_page_margin==9,'defaults changed without confirmation')
config.t_page_margin=20;typeset.unscaled_margins[2]=20;confirm.ok_callback()
assert(defaults.copt_t_page_margin==9 and message=='Page margins changed. Please try again.',
    'stale confirmation changed default margins')
config.t_page_margin=15;typeset.unscaled_margins[2]=15
require('ui/uimanager'):close(confirm)
button(dialog,'margin_default').callback();confirm=state.confirm
fail_read=true;confirm.ok_callback();fail_read=false
assert(defaults.copt_t_page_margin==9 and defaults.copt_h_page_margins[1]==1,'failed preflight changed defaults')
require('ui/uimanager'):close(confirm)
button(dialog,'margin_default').callback();confirm=state.confirm;fail_write=true;confirm.ok_callback()
assert(defaults.copt_t_page_margin==9 and defaults.copt_h_page_margins[1]==1 and defaults.copt_b_page_margin==nil,
    'failed default write did not restore the previous values')
require('ui/uimanager'):close(confirm)
button(dialog,'margin_default').callback();confirm=state.confirm;confirm.ok_callback()
assert(defaults.copt_h_page_margins[1]==25 and defaults.copt_h_page_margins[2]==25
    and defaults.copt_t_page_margin==15 and defaults.copt_b_page_margin==15 and defaults.copt_sync_t_b_page_margins==0)
require('ui/uimanager'):close(confirm)
button(dialog,'margin_default').callback();confirm=state.confirm;Margins.cancel(host)
defaults.copt_t_page_margin=7;confirm.ok_callback();assert(defaults.copt_t_page_margin==7,'stale confirmation changed defaults')
config.t_page_margin,config.b_page_margin,config.sync_t_b_page_margins=10,10,1
typeset.unscaled_margins[2],typeset.unscaled_margins[4],typeset.sync_t_b_page_margins=10,10,true
state,dialog=open();assert(state.values.sync==1)
G_defaults={readSetting=function() return 999 end}
button(dialog,'margin_compact').callback()
assert(not state.pending and message=='This margin preset is unavailable.','invalid preset was not reported')
G_defaults={readSetting=function(_,key)
    if key:find('_H_',1,true) then return {5,5} end
    if key:find('_T_',1,true) then return 5 end
    if key:find('_B_',1,true) then return 9 end
end}
button(dialog,'margin_compact').callback();assert(state.pending);latest(.4)()
assert(config.t_page_margin==7 and config.b_page_margin==7,'asymmetric preset broke synchronized margins')
G_defaults=nil
button(dialog,'margin_vertical_up').callback();latest(.4)()
assert(config.t_page_margin==12 and config.b_page_margin==12 and config.sync_t_b_page_margins==1)
Margins.cancel(host)
config.h_page_margins={140,140};typeset.unscaled_margins[1],typeset.unscaled_margins[3]=140,140
state,dialog=open();local count=counts.h;button(dialog,'margin_horizontal_up').callback()
assert(not state.pending and counts.h==count,'upper boundary generated a change')
Margins.cancel(host)
typeset.onSetPageTopAndBottomMargin=nil
function typeset:onSetPageTopMargin(value)
    self.unscaled_margins[2]=value
    if self.sync_t_b_page_margins then self.unscaled_margins[4]=value;config.b_page_margin=value end
end
function typeset:onSetPageBottomMargin(value)
    self.unscaled_margins[4]=value
    if self.sync_t_b_page_margins then self.unscaled_margins[2]=value;config.t_page_margin=value end
end
config.t_page_margin,config.b_page_margin,config.sync_t_b_page_margins=10,20,0
typeset.unscaled_margins[2],typeset.unscaled_margins[4],typeset.sync_t_b_page_margins=10,20,false
state,dialog=open();button(dialog,'margin_vertical_up').callback();assert(state.pending);latest(.4)()
assert(config.t_page_margin==15 and config.b_page_margin==25,'older native margin API did not preserve asymmetric values')
Margins.cancel(host)
config.t_page_margin,config.b_page_margin,config.sync_t_b_page_margins=10,10,1
typeset.unscaled_margins[2],typeset.unscaled_margins[4],typeset.sync_t_b_page_margins=10,10,true
state,dialog=open();button(dialog,'margin_vertical_up').callback();assert(state.pending);latest(.4)()
assert(config.t_page_margin==15 and config.b_page_margin==15,'older native margin API broke synchronized values')
Margins.cancel(host)
typeset.unscaled_margins[1]=139;assert(not Margins.show(host,function() return true end)
    and message=='Margin settings are unavailable for this file.')
print('reader_margins_ui_spec: native margins, stale protection and defaults passed')
