-- Select every group through native Menu, verify pages and reject closed callbacks.
return function(plugin,input,mode,report,pump,paint,manifest)
    local UI=require('ui/uimanager')
    local json=require('json')
    local expected=assert(input.expected_groups)
    assert(type(expected)=='table' and #expected<=32 and #expected==#plugin.shelf_groups)
    local coverage={groups=#expected,memberships=0,selected_groups=0,forward_pages=0,reverse_pages=0,
        selector_views=0,checked_memberships=0,empty_groups=0,reference_matches=false,cache_matches=false,
        native_picker_used=false,boundaries_verified=false,closed_callbacks_rejected=false,pluginloader_host=false,filemanager_host=false}
    report.group_coverage=coverage
    local loader=require('pluginloader')
    local manager=assert(require('apps/filemanager/filemanager').instance)
    assert(#loader.enabled_plugins==1 and manager.weread==plugin and plugin.ui==manager)
    coverage.pluginloader_host,coverage.filemanager_host=true,true
    local reference=json.decode('[]')
    for i,group in ipairs(expected) do
        assert(type(group.key)=='string' and type(group.label)=='string' and type(group.members)=='table')
        local actual=assert(plugin.shelf_groups[i]);assert(actual.key==group.key and actual.label==group.label)
        assert(#actual.books==#group.members)
        for j,id in ipairs(group.members) do
            assert(type(id)=='string' and input.expected_shelf[id] and id:sub(1,7)~='MP_WXS_')
            assert(tostring(actual.books[j].bookId)==id)
        end
        coverage.memberships=coverage.memberships+#group.members;assert(coverage.memberships<=1600)
        if #group.members==0 then coverage.empty_groups=coverage.empty_groups+1 end
        reference[#reference+1]={group.key,group.label,group.members}
    end
    local encoded=json.encode(reference)
    if mode=='live' then manifest.groups=encoded else assert(manifest.groups==encoded) end
    coverage.reference_matches=true
    local function tick()
        UI:setInputTimeout(0);UI:handleInput();require('socket').sleep(.005)
    end
    local function select(index,key)
        local view=assert(plugin.shelf_view)
        view:showSourceMenu('books')
        local picker=assert(view._shelf_popup);assert(UI:getTopmostVisibleWidget()==picker)
        assert(#picker.item_table==#expected+1)
        local row=assert(picker.item_table[index]);assert(row.callback)
        if index>1 then assert(row.text==expected[index-1].label) end
        local page=math.floor((index-1)/picker.items_per_page)+1
        while picker.page<page do picker:onNextPage() end
        assert(picker.page==page and picker:getSize().h<=view.screen_h and picker:getSize().w<=view.screen_w)
        UI:forceRePaint();report.painted_views=report.painted_views+1;coverage.selector_views=coverage.selector_views+1
        picker:onMenuSelect(row);pump(function() return plugin.shelf_view and plugin.shelf_view~=view end)
        assert(plugin.shelf_group_key==key and view._shelf_popup==nil and view._shelf_closed)
        local current=plugin.shelf_view;row.callback()
        for _i=1,3 do tick() end
        assert(plugin.shelf_view==current,'dismissed group selector reopened a shelf')
    end
    for i,group in ipairs(expected) do
        select(i+1,group.key);coverage.selected_groups=coverage.selected_groups+1
        local view=assert(plugin.shelf_view);assert(view.mode=='books' and view.group_key==group.key and #view.books==#group.members)
        local members,seen={},{}
        for _id_index,id in ipairs(group.members) do assert(not members[id]);members[id]=true end
        local total=view.page_count
        for page=1,total do
            if page>1 then plugin.shelf_view:onShelfSwipe(nil,{direction='west'}) end
            assert(plugin.shelf_view.page==page and plugin.shelf_view.page_count==total)
            paint('group:'..i,false,true);coverage.forward_pages=coverage.forward_pages+1
            for _book_index,book in ipairs(plugin.shelf_view:getVisibleBooks()) do
                local id=tostring(book.bookId);assert(members[id] and not seen[id]);seen[id]=true
                coverage.checked_memberships=coverage.checked_memberships+1
            end
        end
        for id in pairs(members) do assert(seen[id]) end
        local last=plugin.shelf_view;last:onShelfSwipe(nil,{direction='west'});assert(plugin.shelf_view==last)
        if mode=='reopen' then
            for page=total-1,1,-1 do
                plugin.shelf_view:onShelfSwipe(nil,{direction='east'});assert(plugin.shelf_view.page==page)
                paint('group:'..i,true,true);coverage.reverse_pages=coverage.reverse_pages+1
            end
            local first=plugin.shelf_view;first:onShelfSwipe(nil,{direction='east'});assert(plugin.shelf_view==first)
        end
    end
    select(1,nil)
    local view=assert(plugin.shelf_view)
    view:showSourceMenu('books');local picker=assert(view._shelf_popup)
    local stale=picker.item_table[1].callback
    local old_group=view.on_select_group
    plugin:closeWeReadUI()
    assert(view._shelf_closed and not view._shelf_popup and not plugin.shelf_view)
    stale();old_group(nil)
    for _i=1,3 do tick() end
    assert(not plugin.shelf_view,'closed shelf callback reopened a page')
    coverage.cache_matches,coverage.native_picker_used,coverage.boundaries_verified,coverage.closed_callbacks_rejected=true,true,true,true
end
