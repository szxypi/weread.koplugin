package.path='./?.lua;'..package.path
local tasks,removed={},{}
local device={frontlight=false,eink=false}
function device:hasFrontlight() return self.frontlight end
function device:hasEinkScreen() return self.eink end
package.preload.device=function() return device end
package.preload['ui/uimanager']=function() return {
    show=function() end,close=function(_,view) if view.onCloseWidget then view:onCloseWidget() end end,
    scheduleIn=function(_,_,fn) tasks[#tasks+1]=fn end,unschedule=function(_,fn) removed[fn]=true end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,args)
    function args:setTitle(value) self.title=value end
    return args
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end,
    T=function(v,...) for i=1,select('#',...) do v=v:gsub('%%'..i,tostring(select(i,...))) end;return v end} end
package.preload.gettext=function() return function(v) return v end end
local doc={file='chapter.epub'}
local settings={all_at_once=false,page_progress=true,percentage=true,time=true,
    chapter_time_to_read=false,battery=true,disable_progress_bar=false}
local view={footer_visible=true,flipping_visible=false}
local ui={document=doc,view=view}
local host={ui=ui,_reader_session_gen=1}
package.preload['weread.lib.reader_progress_context']=function() return {capture=function()
    return {ui=ui,document=doc,file=doc.file,session=host._reader_session_gen}
end} end
local saved={footer=settings}
G_reader_settings={readSetting=function(_,key) return saved[key] end,saveSetting=function(_,key,value) saved[key]=value end}
local footer={settings=settings,mode=1,mode_list={off=0,page_progress=1},mode_index={'page_progress','percentage','time'}}
view.footer=footer
function footer:applyFooterMode(value) self.mode=value;view.footer_visible=value~=0 end
function footer:onUpdateFooter() end
function footer:rescheduleFooterAutoRefreshIfNeeded() end
function footer:textOptionTitles(key) return key end
function footer:addToMainMenu(menu)
    local function row(key,invert)
        return {text_func=function() return key end,
            checked_func=function() return invert and not settings[key] or not invert and settings[key] end,
            callback=function() settings[key]=not settings[key] end}
    end
    local bar=row('disable_progress_bar',true);bar.text='Show progress bar';bar.text_func=nil
    menu.status_bar={sub_item_table={{text='Progress bar',sub_item_table={bar}},
        {text='Status bar items',sub_item_table={row('page_progress'),row('percentage'),row('time'),
            row('chapter_time_to_read'),row('battery')}},
        {text='Configure items',sub_item_table={row('all_at_once')}}}}
end
local Display=require('weread.ui.reader_display')
local function find_button(id)
    for _,row in ipairs(host._weread_reader_display.dialog.buttons) do
        for _,item in ipairs(row) do if item.id=='display_'..id then return item end end
    end
end
local function button(id) return assert(find_button(id),'missing button '..id) end
local function flush() local fn=table.remove(tasks);if fn and not removed[fn] then fn() end end
local function click(id) assert(button(id).enabled~=false);button(id).callback();flush() end
local message;function host:showInfo(value) message=value end
assert(Display.show(host));local dialog=host._weread_reader_display.dialog
assert(dialog.title:find('cycle one at a time',1,true))
assert(not find_button('frontlight') and not find_button('full_refresh'))
click('all_at_once');assert(settings.all_at_once and dialog.title:find('shown together',1,true))
click('percentage');assert(not settings.percentage and button('percentage').text:find('Off',1,true))
click('progress_bar');assert(settings.disable_progress_bar)
click('visible');assert(not view.footer_visible and saved.reader_footer_mode==0)
click('visible');assert(view.footer_visible and saved.reader_footer_mode==1)
local stale=button('time').callback;host._reader_session_gen=2;stale()
assert(settings.time and not host._weread_reader_display,'stale session changed settings')
assert(Display.show(host));stale=button('time').callback;saved.footer={};stale()
assert(settings.time and not host._weread_reader_display,'detached settings changed')
saved.footer=settings;settings.disabled=true;assert(not Display.show(host) and message:find('disabled',1,true))
settings.disabled=false;assert(Display.show(host));stale=button('time').callback;footer.settings=nil;stale()
assert(settings.time and not host._weread_reader_display,'missing settings changed')
footer.settings=settings
local lights,refreshes=0,0
function device:showLightDialog()
    assert(not host._weread_reader_display,'frontlight was opened over the temporary panel')
    lights=lights+1
end
local ui_manager=require('ui/uimanager')
function ui_manager:setDirty(widget,mode)
    assert(not host._weread_reader_display,'refresh was requested with the temporary panel visible')
    assert(widget=='all' and mode=='full')
    refreshes=refreshes+1
end
device.frontlight=true;device.eink=true;settings.disabled=true
assert(Display.show(host) and not find_button('visible'),'disabled footer hid the device controls')
click('frontlight');assert(lights==1 and refreshes==0)
assert(Display.show(host));click('full_refresh');assert(lights==1 and refreshes==1)
view.footer=nil;device.frontlight=false
assert(Display.show(host) and not find_button('frontlight') and not find_button('visible'))
stale=button('full_refresh').callback
assert(Display.show(host));local replacement=host._weread_reader_display
stale();assert(refreshes==1 and host._weread_reader_display==replacement,'stale refresh disturbed the newer panel')
stale=button('full_refresh').callback;host._weread_suspended=true;stale()
assert(refreshes==1 and not host._weread_reader_display and not Display.show(host),'sleep allowed a refresh')
host._weread_suspended=false;device.eink=false;device.frontlight=true
assert(Display.show(host) and not find_button('full_refresh'))
stale=button('frontlight').callback;host._reader_session_gen=3;stale()
assert(lights==1 and not host._weread_reader_display,'closed reader opened the frontlight')
print('reader_display_ui_spec: native footer, frontlight, full refresh, capability and session checks passed')
