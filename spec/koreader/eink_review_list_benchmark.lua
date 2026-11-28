-- Synthetic review list: compare the original full paint with clipped paint.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
if os.getenv('WEREAD_REVIEW_NO_XTEXT')=='1' then G_reader_settings:saveSetting('use_xtext',false) end
if os.getenv('WEREAD_REVIEW_FLASH')=='1' then G_reader_settings:saveSetting('flash_ui',true) end
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local FocusNav=require('weread.ui.focus_nav')
local FocusManager=require('ui/widget/focusmanager')
local VerticalGroup=require('ui/widget/verticalgroup')
local Event=require('ui/event')
local Geom=require('ui/geometry')
local json=require('json')
local ReviewView=require('weread.ui.book_reviews_view')
if os.getenv('WEREAD_REVIEW_RTL')=='1' then require('ui/bidi')._mirrored_ui_layout=true end
if os.getenv('WEREAD_REVIEW_NO_XTEXT')=='1' then assert(not require('ui/widget/textwidget').use_xtext) end
local items={}
for i=1,200 do
    local author=i%4==0 and string.rep('超长测试读者😀',12)..i or '合成读者 '..i
    local content=i%3==0 and string.rep('长内容包含英文、中文与表情😀 ',20)..i
        or '合成书评内容，用于检查屏幕内外的文字渲染 '..i
    items[i]={author=author,rating=i%5+1,create_time=1700000000+i,content=content}
end
local selected,loaded
local BookReviews=require('weread.lib.book_reviews')
local preview=BookReviews.preview
local preview_calls=0
BookReviews.preview=function(...)
    preview_calls=preview_calls+1
    return preview(...)
end
local data={book_title='合成书籍',mode='latest',result={items=items,has_more=true},latest_only=true,native_filters=true}
local callbacks={on_select=function(item) selected=item end,on_load_more=function() loaded=true end}
local started=os.clock()
local view=ReviewView.show(data,callbacks)
UI:setDirty(view,'ui');UI:forceRePaint()
local initial_cpu_ms=math.floor((os.clock()-started)*1000+.5)
local initial_previews=preview_calls
assert(#view._review_buttons==201)
local width_checksum,height_checksum=0,0
for i,row in ipairs(view._review_buttons) do
    local size=row:getSize();width_checksum=width_checksum+i*size.w;height_checksum=height_checksum+i*size.h
end
local function materialized()
    local count=0
    for _,row in ipairs(view._review_buttons) do if row.frame then count=count+1 end end
    return count
end
local initial_materialized=materialized()
collectgarbage('collect');local initial_lua_kib=math.floor(collectgarbage('count'))
local max_materialized=initial_materialized
local measured_optimized,review_layout_updates=0,0
for _,button in ipairs(view._review_buttons) do
    local old=button.paintTo
    local original_position=button.setOffscreenGeometry
    button.paintTo=function(self,...)
        measured_optimized=measured_optimized+1
        if original_position then review_layout_updates=review_layout_updates+1 end
        return old(self,...)
    end
    if original_position then
        button.setOffscreenGeometry=function(self,...)
            review_layout_updates=review_layout_updates+1
            return original_position(self,...)
        end
    end
end
local scroll=view._review_scroll
local total=view._review_content:getSize().h
local offsets={0,math.floor(total*.25),math.floor(total*.5),math.max(0,total-scroll.dimen.h)}
local dir=assert(os.getenv('WEREAD_REVIEW_SHOTS'))
for index,target in ipairs(offsets) do
    scroll:_scrollBy(0,target-(scroll:getScrolledOffset().y or 0))
    UI:setDirty(view,'ui');UI:forceRePaint();Device.screen:shot(dir..'/optimized-'..index..'.png')
    max_materialized=math.max(max_materialized,materialized())
end
local paint_count,layout_count=measured_optimized,review_layout_updates
-- Keep the reference widgets separate so full painting never changes the
-- candidate's retained row frames or cached previews.
local reference=ReviewView.show(data,callbacks)
local reference_scroll=reference._review_scroll
reference_scroll:initState()
reference._review_content.paintTo=VerticalGroup.paintTo
local original_paints=0
for _,button in ipairs(reference._review_buttons) do
    local original=button.paintTo
    button.paintTo=function(self,...)
        original_paints=original_paints+1
        return original(self,...)
    end
end
for index,target in ipairs(offsets) do
    reference_scroll:_scrollBy(0,target-reference_scroll:getScrolledOffset().y)
    UI:setDirty(reference,'ui');UI:forceRePaint();Device.screen:shot(dir..'/original-'..index..'.png')
end
UI:close(reference)
UI:forceRePaint()
local prepaint_press=os.getenv('WEREAD_REVIEW_PREPAINT_PRESS')=='1'
for _,index in ipairs({1,100,200}) do
    view:moveFocusTo(1,index+1,FocusManager.FORCED_FOCUS)
    FocusNav.scrollToFocused(view)
    if prepaint_press then
        selected=nil;view:onPress()
        assert(selected==items[index],'Press selected the wrong review after scrolling')
    end
    UI:setDirty(view,'ui');UI:forceRePaint()
    local row=view._review_buttons[index]
    assert(row.dimen.y>=scroll.dimen.y and row.dimen.y+row.dimen.h<=scroll.dimen.y+scroll.dimen.h,
        'focused review was not scrolled into view')
    local pos=Geom:new{x=row.dimen.x+math.floor(row.dimen.w/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
    selected=nil;UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}))
    assert(selected==items[index],'tap selected the wrong review')
end
view:moveFocusTo(1,101,FocusManager.FORCED_FOCUS)
FocusNav.scrollToFocused(view);UI:setDirty(view,'ui');UI:forceRePaint()
local focused=view._review_buttons[100]
assert(focused.frame and focused.frame.invert,'focused review is not highlighted')
scroll:_scrollBy(0,-scroll:getScrolledOffset().y);UI:setDirty(view,'ui');UI:forceRePaint()
if initial_materialized<201 then assert(not focused.frame,'offscreen focus retained its frame') end
FocusNav.scrollToFocused(view);UI:setDirty(view,'ui');UI:forceRePaint()
assert(focused.frame and focused.frame.invert,'review focus highlight was not restored')
view:moveFocusTo(1,202,FocusManager.FORCED_FOCUS)
FocusNav.scrollToFocused(view)
if prepaint_press then
    view:onPress();assert(loaded,'Press did not activate Load more after scrolling')
    loaded=nil
end
UI:setDirty(view,'ui');UI:forceRePaint()
local more=view._review_buttons[201]
local pos=Geom:new{x=more.dimen.x+math.floor(more.dimen.w/2),y=more.dimen.y+math.floor(more.dimen.h/2)}
UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}));assert(loaded,'load more was not activated')
local visits=0
for _,row in ipairs(view._review_buttons) do
    local original=row.handleEvent
    row.handleEvent=function(self,event,...)
        if event.handler=='onGesture' then visits=visits+1 end
        return original(self,event,...)
    end
end
for _=1,200 do UI:sendEvent(Event:new('Gesture',{ges='hold_release',pos=pos})) end
assert(visits==200,'point gestures visited an unexpected number of rows')
local optimized_visits=visits
visits=0
local dispatch=view._review_content.propagateEvent
view._review_content.propagateEvent=VerticalGroup.propagateEvent
for _=1,200 do UI:sendEvent(Event:new('Gesture',{ges='hold_release',pos=pos})) end
local original_visits=visits
view._review_content.propagateEvent=dispatch
visits=0
local before=scroll:getScrolledOffset().y
UI:sendEvent(Event:new('Gesture',{ges='swipe',pos=pos,direction='south'}))
assert(scroll:getScrolledOffset().y<before,'swipe did not reach the scroller')
assert(visits==0,'swipe visited review rows')
UI:close(view)
-- The native Button can finish its press feedback even when the callback
-- closes the view immediately.
local closing
closing=ReviewView.show({book_title='合成书籍',mode='latest',result={items={items[1]}},
    incomplete_text='合成提示',scroll_offset=prepaint_press and {x=0,y=5000} or nil},
    {on_select=function() UI:close(closing) end})
UI:setDirty(closing,'ui');UI:forceRePaint()
if prepaint_press then assert(closing._review_scroll:getScrolledOffset().y==0,'short results kept an invalid offset') end
local last=closing._review_buttons[1]
local last_pos=Geom:new{x=last.dimen.x+math.floor(last.dimen.w/2),y=last.dimen.y+math.floor(last.dimen.h/2)}
UI:sendEvent(Event:new('Gesture',{ges='tap',pos=last_pos}))
assert(closing._review_closed,'press did not close the view')
print('\nWEREAD_REVIEW_LIST_BENCHMARK='..json.encode({result='PASS',original=original_paints,
    optimized=paint_count,items=#items,frames=#offsets,event_visits=optimized_visits,
    original_event_visits=original_visits,initial_materialized=initial_materialized,
    max_materialized=max_materialized,initial_lua_kib=initial_lua_kib,initial_cpu_ms=initial_cpu_ms,
    initial_previews=initial_previews,review_layout_updates=layout_count,prepaint_press_verified=prepaint_press,
    width_checksum=width_checksum,height_checksum=height_checksum}))
