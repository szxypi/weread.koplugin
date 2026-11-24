-- Synthetic review list: compare the original full paint with clipped paint.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local FocusNav=require('weread.ui.focus_nav')
local FocusManager=require('ui/widget/focusmanager')
local VerticalGroup=require('ui/widget/verticalgroup')
local Event=require('ui/event')
local Geom=require('ui/geometry')
local json=require('json')
if os.getenv('WEREAD_REVIEW_RTL')=='1' then require('ui/bidi')._mirrored_ui_layout=true end
local items={}
for i=1,200 do
    items[i]={author='合成读者 '..i,rating=i%5+1,create_time=1700000000+i,
        content='合成书评内容，用于检查屏幕内外的文字渲染 '..i}
end
local selected,loaded
local view=require('weread.ui.book_reviews_view').show({book_title='合成书籍',mode='latest',
    result={items=items,has_more=true},latest_only=true,native_filters=true},
    {on_select=function(item) selected=item end,on_load_more=function() loaded=true end})
UI:setDirty(view,'ui');UI:forceRePaint()
assert(#view._review_buttons==201)
local counts={optimized=0,original=0}
local phase='optimized'
for _,button in ipairs(view._review_buttons) do
    local old=button.paintTo
    button.paintTo=function(self,...)
        counts[phase]=counts[phase]+1
        return old(self,...)
    end
end
local scroll=view._review_scroll
local total=view._review_content:getSize().h
local offsets={0,math.floor(total*.25),math.floor(total*.5),math.max(0,total-scroll.dimen.h)}
local dir=assert(os.getenv('WEREAD_REVIEW_SHOTS'))
local optimized=view._review_content.paintTo
for index,target in ipairs(offsets) do
    scroll:_scrollBy(0,target-(scroll:getScrolledOffset().y or 0))
    phase='optimized';view._review_content.paintTo=optimized
    UI:setDirty(view,'ui');UI:forceRePaint();Device.screen:shot(dir..'/optimized-'..index..'.png')
    phase='original';view._review_content.paintTo=VerticalGroup.paintTo
    UI:setDirty(view,'ui');UI:forceRePaint();Device.screen:shot(dir..'/original-'..index..'.png')
end
view._review_content.paintTo=optimized;phase='optimized'
local measured_optimized=counts.optimized
for _,index in ipairs({1,100,200}) do
    view:moveFocusTo(1,index+1,FocusManager.FORCED_FOCUS)
    FocusNav.scrollToFocused(view);UI:setDirty(view,'ui');UI:forceRePaint()
    local row=view._review_buttons[index]
    assert(row.dimen.y>=scroll.dimen.y and row.dimen.y+row.dimen.h<=scroll.dimen.y+scroll.dimen.h,
        'focused review was not scrolled into view')
    local pos=Geom:new{x=row.dimen.x+math.floor(row.dimen.w/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
    selected=nil;UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}))
    assert(selected==items[index],'tap selected the wrong review')
end
view:moveFocusTo(1,202,FocusManager.FORCED_FOCUS)
FocusNav.scrollToFocused(view);UI:setDirty(view,'ui');UI:forceRePaint()
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
print('\nWEREAD_REVIEW_LIST_BENCHMARK='..json.encode({result='PASS',original=counts.original,
    optimized=measured_optimized,items=#items,frames=#offsets,event_visits=optimized_visits,
    original_event_visits=original_visits}))
