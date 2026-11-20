-- The real native renderer, using only this run's closed synthetic bookmark.
return function(reader,plugin,pump,shot,clean,id)
    local UI=require('ui/uimanager');local Event=require('ui/event')
    local origin=reader.document:getXPointer();local mode=reader.view.view_mode
    pump(function() return plugin._personal_marks and plugin._personal_marks.complete end)
    local s=plugin._personal_marks;local record
    for _i,row in ipairs(s.bookmarks) do if row.bookmarkId==id then record=row end end
    assert(record and not record.pos1,'point bookmark did not project separately')
    local function paint()
        UI:setInputTimeout(0);UI:handleInput();clean(reader);UI:setDirty(reader,'ui');UI:forceRePaint()
    end
    reader:handleEvent(Event:new('SetViewMode','page'));reader.rolling:onGotoXPointer(record.pos0);paint()
    assert(s.indicator.rect and s.indicator.visible[1].bookmarkId==id,'bookmarked page has no native corner '..require('json').encode{
        enabled=s.indicator.enabled,points=#s.bookmarks,visible=#s.indicator.visible,mode=reader.view.view_mode,
        membership=reader.document:isXPointerInCurrentPage(record.pos0),margins=reader.document:getPageMargins(),
        dimen=reader.dimen,geometry=s.indicator:geometry()})
    shot('bookmark-indicator-page')
    local page=reader.document:getPageFromXPointer(record.pos0)
    local other=page<reader.document:getPageCount() and page+1 or page-1
    assert(other>=1);reader.rolling:onGotoPage(other);paint()
    assert(not s.indicator.rect and #s.indicator.visible==0,'next page kept cloud corner')
    reader.rolling:onGotoXPointer(record.pos0);paint();assert(s.indicator.rect)
    plugin:toggleAnnotationVisibility();paint();assert(not s.indicator.enabled and not s.indicator.rect)
    plugin:toggleAnnotationVisibility();pump(function() return s.complete end);paint();assert(s.indicator.rect)
    local local_dogear=reader.view.dogear_visible
    reader.view.dogear:onSetDogearVisibility(true);paint()
    local r=assert(s.indicator.rect);local native=reader.view.dogear:getRefreshRegion()
    assert(r.x+r.w<=native.x or r.x>=native.x+native.w or r.y+r.h<=native.y or r.y>=native.y+native.h,
        'cloud corner overlaps native dogear')
    shot('bookmark-indicator-with-local');reader.view.dogear:onSetDogearVisibility(local_dogear)
    local font=reader.font.configurable.font_size
    reader.font:onSetFontSize(font+2);reader.rolling:onGotoXPointer(record.pos0);paint()
    assert(s.indicator.rect,'font reflow lost cloud point')
    reader.font:onSetFontSize(font);reader.rolling:onGotoXPointer(record.pos0);paint()
    reader:handleEvent(Event:new('SetViewMode','scroll'));reader.rolling:onGotoXPointer(record.pos0);paint()
    assert(s.indicator.rect,'visible scroll point has no corner');shot('bookmark-indicator-scroll')
    r=s.indicator.rect
    assert(plugin:_onXPointerOverlayTap{pos={x=r.x+r.w/2,y=r.y+r.h/2}},'corner tap did not route')
    local owner=assert(plugin._my_marks_owner)
    assert(owner.bookmarks and owner.menu._shelf_popup,'corner tap did not open the matching bookmark')
    plugin:cancelMyCloudMarks();clean(reader)
    reader:handleEvent(Event:new('SetViewMode',mode));reader.rolling:onGotoXPointer(origin);paint()
    assert(reader.view.dogear_visible==local_dogear and reader.view.view_mode==mode)
    local file=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/bookmark-indicator-result.json','wb'))
    file:write(require('json').encode{result='PASS',synthetic_only=true,native_point_verified=true,page_turn_hides=true,
        show_toggle=true,font_reflow=true,scroll_visible=true,corner_tap=true,local_dogear_preserved=true,real_account_data_posts=0})
    file:close()
end
