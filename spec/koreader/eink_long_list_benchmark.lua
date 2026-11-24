-- Synthetic long-list benchmark; no account, network, or private data.
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
    if os.getenv('WEREAD_LONG_LIST_NO_XTEXT')=='1' then G_reader_settings:saveSetting('use_xtext',false) end
    local Device=require('device');require('document/canvascontext'):init(Device)
    if os.getenv('WEREAD_LONG_LIST_RTL')=='1' then require('ui/bidi')._mirrored_ui_layout=true end
    if os.getenv('WEREAD_LONG_LIST_NO_XTEXT')=='1' then
        assert(require('ui/widget/textwidget').use_xtext==false,'text shaping was not disabled')
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local books,local_pins={},{}
    for i=1,1500 do
        books[i]={bookId=tostring(i),title=i%3==0 and ('合成长书名用于验证截断 '..i) or ('合成长书架 '..i),
            author='测试',_shelf_progress=(i*7)%100,finishReading=i%7==0 and 1 or 0,
            secret=i%5==0 and 1 or 0,isTop=i%9==0 and 1 or 0}
        if i%29==0 then
            local_pins[tostring(i)]=true
            books[i]._cached=true;books[i].secret=1;books[i].isTop=1
            books[i]._shelf_progress=0;books[i]._shelf_progress_local=true;books[i]._shelf_progress_exact=0.25
        end
    end
    local selected,held
    local start=socket.gettime()
    local view=require('weread.ui.library_view').show({mode='books',books=books,local_pins=local_pins,paged=false,cover_mode=false,
        title='合成长书架'}, {on_select=function(book) selected=book end,on_hold=function(book) held=book end})
    UI:forceRePaint()
    local build_ms=math.floor((socket.gettime()-start)*1000+.5)
    assert(#view._item_rows==#books and view.scroll.dimen.h>0)
    local total,frame_count,width_checksum,height_checksum=0,0,0,0
    for i,row in ipairs(view._item_rows) do
        local size=row:getSize();total=total+size.h+1
        width_checksum=width_checksum+i*size.w;height_checksum=height_checksum+i*size.h
        if row.frame then frame_count=frame_count+1 end
    end
    local offset={y=0};local get_offset=view.scroll.getScrolledOffset
    view.scroll.getScrolledOffset=function() return offset end
    local function reference(top)
        local y,result=0,{}
        for index,row in ipairs(view._item_rows) do
            local bottom=y+row:getSize().h
            if bottom>top and y<top+view.scroll.dimen.h then result[#result+1]=books[index] end
            if y>=top+view.scroll.dimen.h then break end
            y=bottom+1
        end
        return result
    end
    local offsets={0,math.floor(total*.25),math.floor(total*.5),math.max(0,total-view.scroll.dimen.h)}
    for _,top in ipairs(offsets) do
        offset.y=top;local actual,expected=view:getVisibleBooks(),reference(top)
        assert(#actual==#expected)
        for i,book in ipairs(expected) do assert(actual[i]==book) end
    end
    collectgarbage('collect');local memory=math.floor(collectgarbage('count'))
    local cpu,wall=os.clock(),socket.gettime()
    for i=1,2000 do offset.y=offsets[(i-1)%#offsets+1];assert(#view:getVisibleBooks()>0) end
    local lookup_wall=math.floor((socket.gettime()-wall)*1000+.5)
    local lookup_cpu=math.floor((os.clock()-cpu)*1000+.5)
    view.scroll.getScrolledOffset=get_offset
    local painted=0
    local max_materialized=frame_count
    for _,row in ipairs(view._item_rows) do
        local original=row.paintTo
        row.paintTo=function(self,...) painted=painted+1;return original(self,...) end
    end
    wall=socket.gettime()
    for i=1,8 do
        local target=offsets[(i-1)%#offsets+1]
        view.scroll:_scrollBy(0,target-(view:getScrollOffset().y or 0))
        UI:forceRePaint()
        local materialized=0
        for _,item in ipairs(view._item_rows) do if item.frame then materialized=materialized+1 end end
        max_materialized=math.max(max_materialized,materialized)
        if i<=4 and os.getenv('WEREAD_LONG_LIST_SHOTS') then
            Device.screen:shot(os.getenv('WEREAD_LONG_LIST_SHOTS')..'/'..i..'.png')
        end
    end
    local repaint_ms=math.floor((socket.gettime()-wall)*1000+.5)
    local paint_count=painted
    local top=view.scroll.dimen.y;local bottom=top+view.scroll.dimen.h
    local row,book
    for i,candidate in ipairs(view._item_rows) do
        if candidate.dimen.y>=top and candidate.dimen.y+candidate.dimen.h<=bottom then row,book=candidate,books[i];break end
    end
    assert(row and book)
    local pos=require('ui/geometry'):new{x=row.dimen.x+math.floor(row.dimen.w/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
    local Event=require('ui/event')
    UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}));assert(selected==book,'tap selected an offscreen book')
    UI:sendEvent(Event:new('Gesture',{ges='hold',pos=pos}));assert(held==book,'hold selected an offscreen book')
    local event_rows=0
    for _,candidate in ipairs(view._item_rows) do
        local original=candidate.handleEvent
        candidate.handleEvent=function(self,event,...)
            if event.handler=='onGesture' then event_rows=event_rows+1 end
            return original(self,event,...)
        end
    end
    local event_start=socket.gettime()
    for _=1,200 do UI:sendEvent(Event:new('Gesture',{ges='hold_release',pos=pos})) end
    local event_ms=math.floor((socket.gettime()-event_start)*1000+.5)
    local event_visits=event_rows
    local scroll_before=view:getScrollOffset().y
    local scroll_visit_start=event_rows
    UI:sendEvent(Event:new('Gesture',{ges='swipe',pos=pos,direction='south'}))
    assert(view:getScrollOffset().y<scroll_before,'swipe did not reach the native scroller')
    UI:forceRePaint()
    scroll_before=view:getScrollOffset().y
    UI:sendEvent(Event:new('Gesture',{ges='touch',pos=pos}))
    UI:sendEvent(Event:new('Gesture',{ges='pan',pos=pos,relative={x=0,y=100}}))
    UI:sendEvent(Event:new('Gesture',{ges='pan_release',pos=pos}))
    assert(view:getScrollOffset().y<scroll_before,'pan did not reach the native scroller')
    UI:forceRePaint()
    local scroll_event_visits=event_rows-scroll_visit_start
    local FocusNav=require('weread.ui.focus_nav')
    for _,index in ipairs({1,750,1500}) do
        row=view._item_rows[index];local layout_index
        for i,focus_row in ipairs(view.layout) do if focus_row[1]==row then layout_index=i;break end end
        assert(layout_index)
        view:moveFocusTo(1,layout_index,require('ui/widget/focusmanager').FORCED_FOCUS)
        FocusNav.scrollToFocused(view);UI:forceRePaint()
        assert(row.dimen.y>=view.scroll.dimen.y and row.dimen.y+row.dimen.h<=view.scroll.dimen.y+view.scroll.dimen.h,
            'focus did not scroll an offscreen row into view')
        pos=require('ui/geometry'):new{x=row.dimen.x+math.floor(row.dimen.w/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
        selected=nil;UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}))
        assert(selected==books[index],'focus or tap activated the wrong book after scrolling')
    end
    -- The selected row can leave and re-enter the viewport without losing
    -- the focus highlight, even when its visible content is discarded.
    for _,index in ipairs({1499,1500}) do
        local wanted=view._item_rows[index]
        for i,focus_row in ipairs(view.layout) do
            if focus_row[1]==wanted then
                view:moveFocusTo(1,i,require('ui/widget/focusmanager').FORCED_FOCUS);break
            end
        end
    end
    local focused=view._item_rows[1500]
    assert(focused.frame and focused.frame.invert,'focused row is not highlighted')
    view.scroll:_scrollBy(0,-view:getScrollOffset().y);UI:forceRePaint()
    FocusNav.scrollToFocused(view);UI:forceRePaint()
    assert(focused.frame and focused.frame.invert,'focused row lost its highlight after scrolling away')
    UI:close(view)

    -- Compare the real eager layout with the continuous layout for every row,
    -- including long public-account names whose status can overflow the row.
    local accounts={}
    for i=1,140 do
        accounts[i]={bookId='MP_WXS_'..i,title=string.rep('公众号标题😀',12)..i,
            author=string.rep('宽',i%80)..' Café'}
    end
    local View=require('weread.ui.library_view')
    local eager=View.show({mode='public_account',accounts=accounts,cover_mode=false,paged=true,page_size=#accounts}, {})
    UI:forceRePaint()
    if os.getenv('WEREAD_LONG_LIST_SHOTS') then Device.screen:shot(os.getenv('WEREAD_LONG_LIST_SHOTS')..'/account-eager.png') end
    local sizes,overflow={},false
    for i,item in ipairs(eager._item_rows) do
        local size=item:getSize();sizes[i]={w=size.w,h=size.h}
        if size.w>eager.list_width then overflow=true end
    end
    assert(overflow,'long status fixture did not exercise overflowing layout')
    UI:close(eager)
    local account_selected
    local account_view=View.show({mode='public_account',accounts=accounts,cover_mode=false,paged=false},
        {on_select=function(account) account_selected=account end})
    UI:forceRePaint()
    if os.getenv('WEREAD_LONG_LIST_SHOTS') then Device.screen:shot(os.getenv('WEREAD_LONG_LIST_SHOTS')..'/account-lazy.png') end
    for i,item in ipairs(account_view._item_rows) do
        local size=item:getSize()
        assert(size.w==sizes[i].w and size.h==sizes[i].h,
            ('continuous row geometry differs: index=%d width=%d expected=%d height=%d expected=%d')
                :format(i,size.w,sizes[i].w,size.h,sizes[i].h))
    end
    account_view.scroll:_scrollBy(0,account_view.scroll._max_scroll_offset_y);UI:forceRePaint()
    local visible_top,visible_bottom=account_view.scroll.dimen.y,account_view.scroll.dimen.y+account_view.scroll.dimen.h
    local account_row,account_book
    for i,item in ipairs(account_view._item_rows) do
        if item.dimen.y>=visible_top and item.dimen.y+item.dimen.h<=visible_bottom then
            account_row,account_book=item,accounts[i];break
        end
    end
    assert(account_row and account_book)
    local left=math.max(account_row.dimen.x,account_view.scroll.dimen.x)
    local right=math.min(account_row.dimen.x+account_row.dimen.w,account_view.scroll.dimen.x+account_view.scroll.dimen.w)
    assert(right>left,'public account row lies outside the viewport')
    pos=require('ui/geometry'):new{x=left+math.floor((right-left)/2),
        y=account_row.dimen.y+math.floor(account_row.dimen.h/2)}
    UI:sendEvent(Event:new('Gesture',{ges='tap',pos=pos}))
    assert(account_selected==account_book,'public-account row tap failed after scrolling')
    UI:close(account_view)
    report={result='PASS',books=#books,queries=2000,initialization_ms=build_ms,
        lookup_wall_ms=lookup_wall,lookup_cpu_ms=lookup_cpu,
        repaint_wall_ms=repaint_ms,row_paints=paint_count,gesture_verified=true,focus_verified=true,
        event_row_visits=event_visits,event_dispatch_ms=event_ms,scroll_event_row_visits=scroll_event_visits,
        swipe_verified=true,pan_verified=true,
        initial_materialized_rows=frame_count,max_materialized_rows=max_materialized,
        row_width_checksum=width_checksum,row_height_checksum=height_checksum,
        account_geometry_verified=true,account_scroll_verified=true,focus_reentry_verified=true,
        mirrored=os.getenv('WEREAD_LONG_LIST_RTL')=='1',
        lua_kib=memory,visible_results_verified=true}
end)
if not ok then report.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,160) end
print('\nWEREAD_LONG_LIST_BENCHMARK='..json.encode(report))
os.exit(ok and 0 or 1)
