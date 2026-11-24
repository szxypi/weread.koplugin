-- Packaged native chapter catalog benchmark, using synthetic data only.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local report={result='UNVERIFIED'}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    if os.getenv('WEREAD_CHAPTER_NO_XTEXT')=='1' then G_reader_settings:saveSetting('use_xtext',false) end
    local Device=require('device');require('document/canvascontext'):init(Device)
    if os.getenv('WEREAD_CHAPTER_RTL')=='1' then require('ui/bidi')._mirrored_ui_layout=true end
    if os.getenv('WEREAD_CHAPTER_NO_XTEXT')=='1' then assert(require('ui/widget/textwidget').use_xtext==false) end
    local UI=require('ui/uimanager');local socket=require('socket')
    local chapters={}
    for i=1,1500 do
        chapters[i]={title=i%3==0 and ('合成长章节标题用于验证截断😀 '..i) or ('第 '..i..' 章'),
            status=i%17==0 and string.rep('宽',35)..i or (i%7==0 and '已缓存' or (i*13)..' 字'),source={id=i}}
    end
    local selected
    local start=socket.gettime()
    local view=require('weread.ui.chapter_list_view').show({title='合成长目录',chapters=chapters},
        {on_select=function(chapter) selected=chapter.id end})
    UI:forceRePaint()
    local build_ms=math.floor((socket.gettime()-start)*1000+.5)
    local rows=view._chapter_rows;assert(#rows==#chapters)
    local scroll=view._nav_scroll;assert(scroll and scroll.dimen.h>0)
    local total,checksum,frames=0,0,0
    local geometry={}
    for i,row in ipairs(rows) do
        local size=row:getSize();total=total+size.h+1;checksum=checksum+i*(size.w+size.h)
        geometry[i]={size.w,size.h}
        if row.frame then frames=frames+1 end
    end
    local initial_frames=frames;local max_frames=frames
    collectgarbage('collect');local heap=math.floor(collectgarbage('count'))
    local painted=0
    for _,row in ipairs(rows) do
        local original=row.paintTo
        row.paintTo=function(self,...) painted=painted+1;return original(self,...) end
    end
    local offsets={0,math.floor(total*.25),math.floor(total*.5),math.max(0,total-scroll.dimen.h)}
    start=socket.gettime()
    for i=1,8 do
        local target=offsets[(i-1)%#offsets+1]
        scroll:_scrollBy(0,target-(scroll:getScrolledOffset().y or 0));UI:forceRePaint()
        frames=0;for _,row in ipairs(rows) do if row.frame then frames=frames+1 end end
        max_frames=math.max(max_frames,frames)
        if i<=4 and os.getenv('WEREAD_CHAPTER_SHOTS') then Device.screen:shot(os.getenv('WEREAD_CHAPTER_SHOTS')..'/'..i..'.png') end
    end
    local repaint_ms=math.floor((socket.gettime()-start)*1000+.5);local row_paints=painted
    local top,bottom=scroll.dimen.y,scroll.dimen.y+scroll.dimen.h
    local visible,index
    for i,row in ipairs(rows) do
        if row.dimen.y>=top and row.dimen.y+row.dimen.h<=bottom then visible,index=row,i;break end
    end
    assert(visible and index)
    local left=math.max(visible.dimen.x,scroll.dimen.x)
    local right=math.min(visible.dimen.x+visible.dimen.w,scroll.dimen.x+scroll.dimen.w)
    assert(right>left)
    local pos=require('ui/geometry'):new{x=left+math.floor((right-left)/2),y=visible.dimen.y+math.floor(visible.dimen.h/2)}
    local Event=require('ui/event')
    UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}));assert(selected==index,'tap activated incorrect chapter')
    local visits=0
    for _,row in ipairs(rows) do
        local original=row.handleEvent
        row.handleEvent=function(self,event,...)
            if event.handler=='onGesture' then visits=visits+1 end
            return original(self,event,...)
        end
    end
    for _=1,200 do UI:sendEvent(Event:new('Gesture',{ges='hold_release',pos=pos})) end
    local event_visits=visits
    local before=scroll:getScrolledOffset().y
    UI:sendEvent(Event:new('Gesture',{ges='swipe',pos=pos,direction='south'}))
    assert(scroll:getScrolledOffset().y<before,'swipe did not reach catalog scroller')
    UI:forceRePaint()
    local FocusNav=require('weread.ui.focus_nav')
    for _,i in ipairs({1,750,1500}) do
        view:moveFocusTo(1,i+1,require('ui/widget/focusmanager').FORCED_FOCUS)
        FocusNav.scrollToFocused(view);UI:forceRePaint()
        local row=rows[i]
        assert(row.dimen.y>=top and row.dimen.y+row.dimen.h<=bottom,'focus outside viewport')
        local x0=math.max(row.dimen.x,scroll.dimen.x)
        local x1=math.min(row.dimen.x+row.dimen.w,scroll.dimen.x+scroll.dimen.w)
        local point=require('ui/geometry'):new{x=x0+math.floor((x1-x0)/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
        selected=nil;UI:sendEvent(Event:new('Gesture',{ges='tap',pos=point}))
        assert(selected==i,'tap selected wrong chapter after focus navigation')
    end
    view:moveFocusTo(1,1500,require('ui/widget/focusmanager').FORCED_FOCUS)
    view:moveFocusTo(1,1501,require('ui/widget/focusmanager').FORCED_FOCUS)
    local focused=rows[1500]
    assert(focused.frame and focused.frame.invert,'focused chapter not highlighted')
    scroll:_scrollBy(0,-scroll:getScrolledOffset().y);UI:forceRePaint()
    FocusNav.scrollToFocused(view);UI:forceRePaint()
    assert(focused.frame and focused.frame.invert,'focus lost after leaving viewport')
    UI:close(view)
    report={result='PASS',chapters=#chapters,initialization_ms=build_ms,repaint_ms=repaint_ms,
        lua_kib=heap,geometry_checksum=checksum,geometry=geometry,row_paints=row_paints,initial_materialized_rows=initial_frames,
        max_materialized_rows=max_frames,event_row_visits=event_visits,tap_verified=true,focus_verified=true}
end)
if not ok then report.error=tostring(reason) end
io.write('\nWEREAD_CHAPTER_BENCHMARK='..json.encode(report)..'\n')
io.flush()
os.exit(ok and 0 or 1)
