-- Read-only long-list interaction using the owner's tmpfs shelf snapshot.
return function(plugin)
    local UI=require('ui/uimanager')
    local settings=plugin.settings:get('shelf')
    local old_view,old_paged=settings.view_mode,settings.paginated
    local old_filters,old_group,old_multi=plugin.shelf_filters,plugin.shelf_group_key,plugin.shelf_multi_groups
    local cover_fetch,progress_fetch=plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress
    plugin:cancelShelfCovers();plugin:cancelShelfProgress()
    plugin.fetchVisibleShelfCovers=function() end;plugin.refreshVisibleShelfProgress=function() end
    settings.view_mode='list';settings.paginated=false;plugin.settings:set('shelf',settings)
    plugin.shelf_filters={};plugin.shelf_group_key=nil;plugin.shelf_multi_groups={}
    plugin:showShelfView('books',nil,plugin.shelf_view)
    local view=assert(plugin.shelf_view)
    assert(not view.paged and not view.cover_mode and #view.books>20 and #view._item_rows==#view.books)
    UI:forceRePaint()
    local maximum=assert(view.scroll._max_scroll_offset_y)
    for _,target in ipairs({0,math.floor(maximum/2),maximum}) do
        view.scroll:_scrollBy(0,target-(view:getScrollOffset().y or 0));UI:forceRePaint()
        local top=view:getScrollOffset().y or 0
        local bottom=top+view.scroll.dimen.h
        local expected,y={},0
        for i,row in ipairs(view._item_rows) do
            local finish=y+row:getSize().h
            if finish>top and y<bottom then expected[#expected+1]=view.books[i] end
            if y>=bottom then break end
            y=finish+1
        end
        local actual=view:getVisibleBooks()
        assert(#actual==#expected,'owner visible-book count differed from independent scan')
        for i,book in ipairs(expected) do assert(actual[i]==book,'owner visible-book order differed from scan') end
    end
    view.scroll:_scrollBy(0,-(view:getScrollOffset().y or 0));UI:forceRePaint()
    local count=0
    for _,row in ipairs(view._item_rows) do
        local original=row.paintTo
        row.paintTo=function(self,...) count=count+1;return original(self,...) end
    end
    view.scroll:_scrollBy(0,view.scroll._max_scroll_offset_y)
    UI:forceRePaint()
    assert(count<#view.books,'long list painted every book after scrolling')
    local visible=view:getVisibleBooks();assert(#visible>0)
    local chosen,selected,held
    local top,bottom=view.scroll.dimen.y,view.scroll.dimen.y+view.scroll.dimen.h
    for i,row in ipairs(view._item_rows) do
        if row.dimen.y>=top and row.dimen.y+row.dimen.h<=bottom then chosen={row=row,book=view.books[i]};break end
    end
    assert(chosen)
    view.on_select=function(book) selected=book end;view.on_hold=function(book) held=book end
    local d=chosen.row.dimen
    local pos=require('ui/geometry'):new{x=d.x+math.floor(d.w/2),y=d.y+math.floor(d.h/2)}
    local Event=require('ui/event')
    UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}));assert(selected==chosen.book)
    UI:sendEvent(Event:new('Gesture',{ges='hold',pos=pos}));assert(held==chosen.book)
    local offset=view:getScrollOffset().y
    UI:sendEvent(Event:new('Gesture',{ges='swipe',pos=pos,direction='south'}))
    assert(view:getScrollOffset().y<offset,'owner shelf swipe did not reach the scroller')
    UI:forceRePaint();offset=view:getScrollOffset().y
    UI:sendEvent(Event:new('Gesture',{ges='touch',pos=pos}))
    UI:sendEvent(Event:new('Gesture',{ges='pan',pos=pos,relative={x=0,y=100}}))
    UI:sendEvent(Event:new('Gesture',{ges='pan_release',pos=pos}))
    assert(view:getScrollOffset().y<offset,'owner shelf pan did not reach the scroller')
    settings=plugin.settings:get('shelf');settings.view_mode=old_view;settings.paginated=old_paged
    plugin.settings:set('shelf',settings);plugin.settings:flush()
    plugin.shelf_filters,plugin.shelf_group_key,plugin.shelf_multi_groups=old_filters,old_group,old_multi
    plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress=cover_fetch,progress_fetch
    return true
end
