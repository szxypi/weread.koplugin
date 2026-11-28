-- Packaged native chapter catalog benchmark, using synthetic data only.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local report={result='UNVERIFIED'}

local function measure_download_selection(chapter_count)
    local UI=require('ui/uimanager')
    local Device=require('device')
    local ChapterList=require('weread.ui.library')
    local Common=require('weread.ui.common')
    local Menu=require('ui/widget/menu')
    local tr=require('weread.lib.i18n').tr
    local chapters={}
    for index=1,chapter_count do
        chapters[index]={chapterUid=index,title='第'..index..'章 合成章节',wordCount=index}
    end
    local host={settings={get=function(_,_,default) return default end},showList=Common.showList,
        safeCallback=function(_,_,callback) return callback end}
    G_reader_settings:saveSetting('items_per_page',14)
    G_reader_settings:saveSetting('items_font_size',20)
    collectgarbage('collect')
    local heap=collectgarbage('count')
    local start=os.clock()
    ChapterList.showChapterDownloadSelection(host,{book_id='123'},chapters)
    local menu=assert(UI:getTopmostVisibleWidget())
    UI:forceRePaint()
    local opening=(os.clock()-start)*1000
    collectgarbage('collect')
    local retained=collectgarbage('count')-heap
    local screenshots=os.getenv('WEREAD_CHAPTER_SHOTS')
    if screenshots then Device.screen:shot(screenshots..'/download-selection.png') end
    local callbacks=0
    for _,item in ipairs(menu.item_table) do
        for _,name in ipairs({'text_func','mandatory_func','select_enabled_func','callback'}) do
            if type(item[name])=='function' then callbacks=callbacks+1 end
        end
    end
    local item=assert(menu.item_table[2])
    start=os.clock()
    menu:onMenuSelect(item)
    UI:forceRePaint()
    local toggle=(os.clock()-start)*1000
    assert(Menu.getMenuText(item):find('[✓]',1,true)==1
        and (item.mandatory_func and item.mandatory_func() or item.mandatory)==tr('Selected'),
        'chapter selection did not update both indicators')
    if screenshots then Device.screen:shot(screenshots..'/download-selected.png') end
    UI:close(menu)
    return {item_functions=callbacks,retained_kib=retained,opening_cpu_ms=opening,toggle_cpu_ms=toggle}
end

local function measure_title_search(chapter_count)
    local Search=require('weread.lib.shelf_search')
    local ChapterSearch=require('weread.ui.chapter_search')
    local utf8proc=require('ffi/utf8proc')
    local rows={}
    for index=1,chapter_count do rows[index]={title='第'..index..'章 ÉLAN'} end
    local function legacy(query)
        local needle=Search.prepare(query)
        local terms=Search.terms(needle)
        local matches,counts,title={},{},{}
        for index,row in ipairs(rows) do
            title.title=row.title
            if Search.matches(title,needle,terms) then
                matches[#matches+1]=index
                counts[row.title]=(counts[row.title] or 0)+1
            end
        end
        return matches,counts
    end
    local lower=assert(utf8proc.lowercase)
    local calls=0
    utf8proc.lowercase=function(...) calls=calls+1;return lower(...) end
    local tests={'Élan '..chapter_count,'Élan　第17章'}
    local function timed(filter)
        collectgarbage('collect')
        local heap=collectgarbage('count')
        local results={}
        for index,query in ipairs(tests) do
            calls=0
            local start=os.clock()
            local matches,counts=filter(query)
            results[index]={cpu=(os.clock()-start)*1000,folds=calls,matches=matches,counts=counts}
        end
        collectgarbage('collect')
        return results,collectgarbage('count')-heap
    end
    local metrics={}
    for trial=1,5 do
        local candidate=ChapterSearch.title_filter(rows)
        local before,after,before_heap,after_heap
        if trial%2==1 then before,before_heap=timed(legacy);after,after_heap=timed(candidate)
        else after,after_heap=timed(candidate);before,before_heap=timed(legacy) end
        for index,measured in ipairs(after) do
            assert(#measured.matches>0 and #measured.matches==#before[index].matches,'search returned a different chapter count')
            for position,match in ipairs(measured.matches) do
                assert(match==before[index].matches[position] and measured.counts[rows[match].title]==before[index].counts[rows[match].title],
                    'search changed chapter order or duplicate counts')
            end
        end
        assert(after[2].folds==1,'another query normalized the existing catalog again')
        metrics[trial]={first_before_ms=before[1].cpu,first_after_ms=after[1].cpu,
            repeat_before_ms=before[2].cpu,repeat_after_ms=after[2].cpu,
            repeat_before_folds=before[2].folds,repeat_after_folds=after[2].folds,extra_retained_kib=after_heap-before_heap}
    end
    utf8proc.lowercase=lower
    local median={}
    for key in pairs(metrics[1]) do
        local values={}
        for index,trial in ipairs(metrics) do values[index]=trial[key] end
        table.sort(values);median[key]=values[3]
    end
    return median
end

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
    local chapter_count=tonumber(os.getenv('WEREAD_CHAPTER_COUNT')) or 1500
    local middle=math.floor(chapter_count/2)
    local chapters={}
    for i=1,chapter_count do
        chapters[i]={title=i%3==0 and ('合成长章节标题用于验证截断😀 '..i) or ('第 '..i..' 章'),
            status=i%17==0 and string.rep('宽',35)..i or (i%7==0 and '已缓存' or (i*13)..' 字'),source={id=i}}
    end
    chapters[middle].status=string.rep('宽',90)
    chapters[middle+1].title=chapters[middle].title
    chapters[middle+2].title,chapters[middle+2].status='',''
    local selected,refreshes=nil,0
    local TextWidget=require('ui/widget/textwidget')
    local new_text_widget=TextWidget.new
    local text_widgets=0
    TextWidget.new=function(self, ...)
        text_widgets=text_widgets+1
        return new_text_widget(self, ...)
    end
    collectgarbage('collect')
    local starting_heap=collectgarbage('count')
    local started_cpu=os.clock()
    local start=socket.gettime()
    local view=require('weread.ui.chapter_list_view').show({title='合成长目录',chapters=chapters},
        {on_select=function(chapter) selected=chapter.id end,on_refresh=function() refreshes=refreshes+1 end})
    UI:forceRePaint()
    local build_ms=math.floor((socket.gettime()-start)*1000+.5)
    local build_cpu_ms=math.floor((os.clock()-started_cpu)*1000+.5)
    TextWidget.new=new_text_widget
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
    collectgarbage('collect');local heap=math.floor(collectgarbage('count')-starting_heap)
    local painted,repositioned=0,0
    for _,row in ipairs(rows) do
        local original=row.paintTo
        row.paintTo=function(self,...) painted=painted+1;return original(self,...) end
        local original_position=row.setOffscreenGeometry
        row.setOffscreenGeometry=function(self,...)
            repositioned=repositioned+1;return original_position(self,...)
        end
    end
    local offsets={0,math.floor(total*.25),math.floor(total*.5),math.max(0,total-scroll.dimen.h)}
    local repaint_cpu=0
    start=socket.gettime()
    for i=1,8 do
        local target=offsets[(i-1)%#offsets+1]
        local started=os.clock()
        scroll:_scrollBy(0,target-(scroll:getScrolledOffset().y or 0));UI:forceRePaint()
        repaint_cpu=repaint_cpu+os.clock()-started
        frames=0;for _,row in ipairs(rows) do if row.frame then frames=frames+1 end end
        max_frames=math.max(max_frames,frames)
        if i<=4 and os.getenv('WEREAD_CHAPTER_SHOTS') then Device.screen:shot(os.getenv('WEREAD_CHAPTER_SHOTS')..'/'..i..'.png') end
    end
    local repaint_ms=math.floor((socket.gettime()-start)*1000+.5)
    local row_paints,row_layout_updates=painted,painted+repositioned
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
    local FocusManager=require('ui/widget/focusmanager')
    local prepaint_press=os.getenv('WEREAD_CHAPTER_PREPAINT_PRESS')=='1'
    view:moveFocusTo(1,1,FocusManager.FORCED_FOCUS)
    view:onPress()
    assert(refreshes==1,'focus activation missed the refresh button')
    for _,i in ipairs({1,middle,chapter_count}) do
        view:moveFocusTo(1,i+1,FocusManager.FORCED_FOCUS)
        FocusNav.scrollToFocused(view)
        if not prepaint_press then UI:forceRePaint() end
        if i~=middle then
            selected=nil;view:onPress()
            assert(selected==i,'Press selected the wrong chapter')
        end
        UI:forceRePaint()
        local row=rows[i]
        assert(row.dimen.y>=top and row.dimen.y+row.dimen.h<=bottom,'focus outside viewport')
        local x0=math.max(row.dimen.x,scroll.dimen.x)
        local x1=math.min(row.dimen.x+row.dimen.w,scroll.dimen.x+scroll.dimen.w)
        local point=require('ui/geometry'):new{x=x0+math.floor((x1-x0)/2),y=row.dimen.y+math.floor(row.dimen.h/2)}
        selected=nil;UI:sendEvent(Event:new('Gesture',{ges='tap',pos=point}))
        assert(selected==i,'tap selected wrong chapter after focus navigation')
    end
    view:moveFocusTo(1,chapter_count,FocusManager.FORCED_FOCUS)
    view:moveFocusTo(1,chapter_count+1,FocusManager.FORCED_FOCUS)
    local focused=rows[chapter_count]
    assert(focused.frame and focused.frame.invert,'focused chapter not highlighted')
    scroll:_scrollBy(0,-scroll:getScrolledOffset().y);UI:forceRePaint()
    selected=nil;view:onPress()
    assert(selected==nil,'Press activated a chapter after touch scrolling it offscreen')
    FocusNav.scrollToFocused(view);UI:forceRePaint()
    assert(focused.frame and focused.frame.invert,'focus lost after leaving viewport')
    local cache_update
    if os.getenv('WEREAD_CHAPTER_CACHE_UPDATE')=='1' then
        local screenshots=os.getenv('WEREAD_CHAPTER_SHOTS')
        local tr=require('weread.lib.i18n').tr
        local last=chapter_count
        while last%17==0 or last%7==0 do last=last-1 end
        view:moveFocusTo(1,last+1,FocusManager.FORCED_FOCUS)
        FocusNav.scrollFocusedToTop(view);UI:forceRePaint()
        local row,chapter=rows[last],chapters[last]
        local old_status=chapters[1].status
        assert(not view:markChaptersCached({[chapters[1].source]=true,[chapters[middle].source]=true})
            and chapters[1].status==old_status,'an unsupported width change partially applied a batch')
        local set_dirty=UI.setDirty
        local region,dirty_count
        UI.setDirty=function(self,widget,kind,rect,...)
            if widget==view then region,dirty_count=rect,(dirty_count or 0)+1 end
            return set_dirty(self,widget,kind,rect,...)
        end
        local margin=scroll:getCropRegion()
        local measurements=0
        local set_text=TextWidget.setText
        TextWidget.setText=function(self,...)
            measurements=measurements+1
            return set_text(self,...)
        end
        local cpu=os.clock()
        assert(view:markChaptersCached({[chapter.source]=true,[chapters[1].source]=true}))
        assert(region and dirty_count==1 and region.h==row.dimen.h and margin:contains(region),
            'a status update refreshed more than the visible chapter row')
        UI.setDirty=set_dirty
        UI:forceRePaint()
        local update_cpu=(os.clock()-cpu)*1000
        local update_measurements=measurements
        assert(chapter.status==tr('Cached') and row.status==tr('Cached') and row.frame.invert
            and rows[1].status==tr('Cached') and not rows[1].frame,'status update lost focus or materialized an offscreen row')
        if screenshots then Device.screen:shot(screenshots..'/cache-updated.png') end
        local position=view:browsingPosition()
        local view_factory=require('weread.ui.chapter_list_view')
        UI:close(view)
        measurements=0;cpu=os.clock()
        view=view_factory.show({title='合成长目录',chapters=chapters,browsing_position=position})
        UI:forceRePaint()
        local rebuild_cpu=(os.clock()-cpu)*1000
        TextWidget.setText=set_text
        assert(view._nav_scroll:getScrolledOffset().y==position.offset.y and view:getFocusItem()==view._chapter_rows[last]
            and view._chapter_rows[last].frame.invert,'rebuilding changed the saved browsing position')
        if screenshots then Device.screen:shot(screenshots..'/cache-rebuilt.png') end
        cache_update={update_measurements=update_measurements,rebuild_measurements=measurements,
            update_cpu_ms=update_cpu,rebuild_cpu_ms=rebuild_cpu,dirty_height=region.h,screen_height=Device.screen:getHeight()}
    end
    UI:close(view)
    report={result='PASS',chapters=#chapters,initialization_ms=build_ms,initialization_cpu_ms=build_cpu_ms,
        initial_text_widgets=text_widgets,repaint_ms=repaint_ms,repaint_cpu_ms=math.floor(repaint_cpu*1000+.5),
        row_layout_updates=row_layout_updates,
        lua_kib=heap,geometry_checksum=checksum,geometry=geometry,row_paints=row_paints,initial_materialized_rows=initial_frames,
        max_materialized_rows=max_frames,event_row_visits=event_visits,tap_verified=true,focus_verified=true,
        press_verified=true,prepaint_press_verified=prepaint_press,cache_update=cache_update,
        title_search=os.getenv('WEREAD_CHAPTER_TITLE_SEARCH')=='1' and measure_title_search(chapter_count) or nil,
        download_selection=os.getenv('WEREAD_CHAPTER_DOWNLOAD_SELECTION')=='1' and measure_download_selection(chapter_count) or nil}
end)
if not ok then report.error=tostring(reason) end
io.write('\nWEREAD_CHAPTER_BENCHMARK='..json.encode(report)..'\n')
io.flush()
os.exit(ok and 0 or 1)
