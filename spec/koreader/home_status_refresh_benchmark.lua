require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
if os.getenv('WEREAD_HOME_RTL')=='1' then require('ui/bidi')._mirrored_ui_layout=true end
local UI=require('ui/uimanager')
local Home=require('weread.lib.home_layout')
local Library=require('weread.ui.library_view')
local preferences=Home.normalize(nil)
local books={}
for i=1,12 do books[i]={bookId=tostring(i),title='合成书籍 '..i,author='测试'} end
local layout=Library.getLayout(true,#books,'books',108,{home=preferences})
local view=Library.show({mode='books',portal=true,home_layout=preferences,title='微信读书',
    status_text='11-24 10:00 · Battery 99% · Wi-Fi connected',summary_text='Today 5 / 30 min',
    books=books,actions={{text='Bookshelf'},{text='Bookstore'}},navigation={{text='Home'},{text='My'}},
    paged=true,cover_mode=true,page=1,page_size=layout.page_size,cover_columns=layout.columns,
    cover_rows=layout.rows}, {on_summary=function() end})
UI:forceRePaint()
local frames=assert(os.getenv('WEREAD_HOME_SHOTS'))
local paint=0;local original=view.paintTo
view.paintTo=function(self,...) paint=paint+1;return original(self,...) end
local direct=0;local original_direct=UI.widgetRepaint
UI.widgetRepaint=function(self,...) direct=direct+1;return original_direct(self,...) end
local original_dirty=UI.setDirty
local captured,regions=nil,{}
UI.setDirty=function(self,widget,mode,region,...)
    if captured and mode=='ui' and region and region.x then
        regions[captured]={x=region.x,y=region.y,w=region.w,h=region.h}
    end
    return original_dirty(self,widget,mode,region,...)
end
local function shot(name)
    UI:forceRePaint();Device.screen:shot(frames..'/'..name..'.png')
end
shot('initial')
for i=1,10 do
    captured='status'..i
    view:updateHomeStatus(('11-24 10:%02d · Battery 99%% · Wi-Fi connected'):format(i))
    captured=nil;shot('status'..i)
end
local status_paints,status_direct=paint,direct
captured='summary1';view:updateHomeSummary('Today 12 / 30 min');captured=nil;shot('summary1')
captured='summary2';view:updateHomeSummary(('Very long reading summary '):rep(12));captured=nil;shot('summary2')
captured='summary3';view:updateHomeSummary('Today 1 / 30 min');captured=nil;shot('summary3')
view._summary_button.did_truncation_tweaks=true
local before_reinit=paint
captured='summary_reinit';view:updateHomeSummary('Rebuilt summary');captured=nil;shot('summary_reinit')
assert(paint>before_reinit,'rebuilt summary did not repaint the view')
local frame=require('ui/widget/container/framecontainer'):new{padding=8,bordersize=1,
    background=require('ffi/blitbuffer').COLOR_WHITE,
    require('ui/widget/textwidget'):new{text='Synthetic overlay',face=require('ui/font'):getFace('cfont',16)}}
UI:show(frame,'ui',nil,20,view._home_status_frame.dimen.y);shot('overlay')
local before_overlay=paint
captured='covered';view:updateHomeStatus('11-24 10:20 · Battery 98%');captured=nil;shot('covered')
assert(paint>before_overlay,'covered home was not repainted in stack order')
UI:close(frame);shot('uncovered')
view._rotation_task=function() end
local before_rotation=paint
captured='rotation';view:updateHomeStatus('11-24 10:21 · Battery 98%');captured=nil;shot('rotation')
view._rotation_task=nil
assert(paint>before_rotation,'pending rotation did not fall back to the full view')
UI.setDirty=original_dirty;UI.widgetRepaint=original_direct
UI:close(view);UI:forceRePaint()
print('\nWEREAD_HOME_STATUS_REFRESH='..require('json').encode({result='PASS',status_view_paints=status_paints,
    status_direct_paints=status_direct,regions=regions,overlay_fallback=true,rotation_fallback=true,
    reinit_fallback=true})..'\n')
