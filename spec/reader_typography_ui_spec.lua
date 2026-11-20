package.path='./?.lua;'..package.path
local shown,tasks,removed={}, {}, {}
package.preload['ui/uimanager']=function() return {
    show=function(_,view) shown[#shown+1]=view end,
    close=function(_,view) if view.onCloseWidget then view:onCloseWidget() end end,
    scheduleIn=function(_,delay,fn) tasks[#tasks+1]={delay=delay,fn=fn} end,
    unschedule=function(_,fn) removed[fn]=true end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,args)
    function args:setTitle(value) self.title=value end
    return args
end} end
package.preload['ui/widget/menu']=function() return {new=function(_,args) return args end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,args) return args end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,
    T=function(value,...) for i=1,select('#',...) do value=value:gsub('%%'..i,tostring(select(i,...))) end;return value end} end
local doc={file='chapter.epub',info={has_pages=false}}
local account='one'
local config={font_size=20,line_spacing=120,font_base_weight=0}
local applied={}
local font={configurable=config,font_face='Original',face_table={}}
function font:onSetFont() end
function font:onSetFontSize(value) config.font_size=value;applied[#applied+1]={'size',value};return true end
function font:onSetLineSpace(value) config.line_spacing=value;applied[#applied+1]={'spacing',value};return true end
function font:onSetFontBaseWeight(value) config.font_base_weight=value;applied[#applied+1]={'weight',value};return true end
local ui={document=doc,font=font}
local host={ui=ui,_reader_session_gen=1,library_db={accountKey=function() return account end}}
package.preload['weread.lib.reader_progress_context']=function() return {capture=function()
    return {ui=ui,document=doc,file=doc.file,session=host._reader_session_gen,account=account}
end} end
local Typography=require('weread.ui.reader_typography')
local function button(dialog,id)
    for _,row in ipairs(dialog.buttons) do for _,item in ipairs(row) do if item.id==id then return item end end end
    error('missing button '..id)
end
local function latest(delay)
    for i=#tasks,1,-1 do if tasks[i].delay==delay and not removed[tasks[i].fn] then return tasks[i].fn end end
    error('missing task')
end
assert(Typography.show(host));local state=host._weread_reader_typography;local dialog=state.dialog
button(dialog,'typography_size_up').callback();local obsolete=latest(.4)
button(dialog,'typography_size_up').callback();assert(removed[obsolete] and #applied==0)
obsolete();assert(#applied==0,'superseded change was applied')
latest(.06)();assert(dialog.title:find('Size 22',1,true))
latest(.4)();assert(#applied==1 and config.font_size==22)
button(dialog,'typography_spacing_up').callback();button(dialog,'typography_close').callback()
assert(config.line_spacing==125 and not host._weread_reader_typography,'close lost pending change')
assert(Typography.show(host));state=host._weread_reader_typography;dialog=state.dialog
button(dialog,'typography_weight_up').callback();local canceled=latest(.4)
account='two';canceled();assert(config.font_base_weight==0,'changed account applied stale setting')
Typography.cancel(host);account='one'
local selected=0
font.face_table={{text_func=function() return 'Second font' end,menu_item_id='Second',callback=function() selected=selected+1;font.font_face='Second' end}}
assert(Typography.show(host));state=host._weread_reader_typography;dialog=state.dialog
button(dialog,'typography_font').callback();local menu=state.menu
assert(menu and #menu.item_table==1);menu.item_table[1].callback()
assert(selected==1 and not state.menu and font.font_face=='Second')
button(dialog,'typography_font').callback();menu=state.menu
Typography.cancel(host);menu.item_table[1].callback();assert(selected==1,'closed font picker accepted stale selection')
assert(Typography.show(host));state=host._weread_reader_typography;dialog=state.dialog
button(dialog,'typography_size_down').callback();local pending=latest(.4)
Typography.cancel(host);pending();assert(config.font_size==22,'canceled panel applied pending change')
local message;function host:showInfo(value) message=value end
assert(Typography.show(host));state=host._weread_reader_typography;dialog=state.dialog
button(dialog,'typography_size_up').callback();config.font_size=30;latest(.4)()
assert(config.font_size==30 and message=='Could not apply reading settings.', 'external font change was overwritten')
Typography.cancel(host)
local defaults={cre_font='Old default',copt_font_size=17};local fail_read,fail_write=false,false
G_reader_settings={readSetting=function(_,key) if fail_read and key=='copt_line_spacing' then error('failed') end;return defaults[key] end,
    saveSetting=function(_,key,value) if fail_write and key=='copt_line_spacing' then fail_write=false;error('failed') end;defaults[key]=value end,
    delSetting=function(_,key) defaults[key]=nil end,
    flush=function(self) return self end}
assert(Typography.show(host));state=host._weread_reader_typography;dialog=state.dialog
button(dialog,'typography_default').callback();local confirm=state.confirm
assert(confirm and defaults.cre_font=='Old default','defaults changed before confirmation')
config.font_size=31;confirm.ok_callback();assert(defaults.cre_font=='Old default','stale settings overwrote defaults')
require('ui/uimanager'):close(confirm);config.font_size=30
button(dialog,'typography_default').callback();confirm=state.confirm;fail_read=true;confirm.ok_callback();fail_read=false
assert(defaults.cre_font=='Old default' and defaults.copt_font_size==17,'failed preflight changed defaults')
require('ui/uimanager'):close(confirm)
button(dialog,'typography_default').callback();confirm=state.confirm;fail_write=true;confirm.ok_callback()
assert(defaults.cre_font=='Old default' and defaults.copt_font_size==17 and defaults.copt_line_spacing==nil,
    'failed write did not restore previous defaults')
require('ui/uimanager'):close(confirm)
button(dialog,'typography_default').callback();confirm=state.confirm;confirm.ok_callback()
assert(defaults.cre_font=='Second' and defaults.copt_font_size==30 and defaults.copt_line_spacing==125
    and defaults.copt_font_base_weight==0,'confirmed defaults did not match current settings')
require('ui/uimanager'):close(confirm)
button(dialog,'typography_default').callback();confirm=state.confirm
Typography.cancel(host);defaults.copt_font_size=12;confirm.ok_callback()
assert(defaults.copt_font_size==12,'closed confirmation changed defaults')
font.face_table={{menu_item_id='Broken',callback=function() error('synthetic font error') end}}
assert(Typography.show(host));state=host._weread_reader_typography;dialog=state.dialog
button(dialog,'typography_font').callback();state.menu.item_table[1].callback()
assert(message=='Could not apply reading settings.','failed font selection was not reported')
Typography.cancel(host)
doc.info.has_pages=true;assert(not Typography.show(host) and message=='Reading settings are unavailable for this file.')
print('reader_typography_ui_spec: native setting queue, ownership and font choice passed')
