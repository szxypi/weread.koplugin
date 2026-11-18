-- Real offline search-history menu and per-account SQLite, synthetic data only.
return function(host,mode,pump,evidence)
    local Cache=require('weread.lib.discovery_cache')
    local cache=Cache:new(host.library_db,host.client)
    local function state(keyword,id)
        return {kind='search',keyword=keyword,cursor=0,next_cursor=0,has_more=false,loaded_at=os.time(),
            source_kind='native',books={{bookId=id,title='合成书籍',author='',category='',cover=''}}}
    end
    if mode=='live' then
        for index=1,10 do assert(cache:write(state('合成查询 '..index,'SYN-'..index))) end
        assert(cache:write(state('合成搜索甲','SYN-ALPHA')))
        assert(cache:write(state('合成搜索乙','SYN-BETA')))
    end
    local per_page=G_reader_settings:readSetting('items_per_page')
    G_reader_settings:saveSetting('items_per_page',5)
    host:closeWeReadUI();host.discovery_state=nil;host:showHome()
    local view=assert(host.shelf_view);view.on_search()
    local dialog=assert(view._shelf_popup)
    view.on_page_changed(view.page);assert(view._shelf_redraw,'fixture did not defer background redraw')
    dialog.buttons[1][3].callback()
    pump(function() return host._discovery_menu~=nil or host.saved_searches_job==nil end)
    local menu=assert(host._discovery_menu,'saved searches menu failed to open')
    assert(host.shelf_view==view and view._shelf_popup==menu and view._shelf_redraw,
        'background redraw replaced the saved-search menu')
    assert(#menu.item_table==12 and menu.item_table[1].text=='合成搜索乙' and menu.item_table[2].text=='合成搜索甲',
        'saved searches are not in most recently saved order')
    assert(menu.page_num>1,'saved search pagination fixture did not paginate')
    require('ui/uimanager'):forceRePaint()
    require('device').screen:shot(evidence..'/saved-searches.png')
    menu:onGotoPage(menu.page_num);assert(menu.page==menu.page_num)
    menu:onMenuSelect(menu.item_table[12])
    pump(function() return host.discovery_state and host.discovery_state.kind=='search' end)
    assert(host.discovery_state.cached and host.discovery_state.keyword=='合成查询 1'
        and host.shelf_view.books[1].bookId=='SYN-1','older saved search did not reopen')
    view=assert(host.shelf_view);view.on_search();dialog=assert(view._shelf_popup);dialog.buttons[1][3].callback()
    pump(function() return host._discovery_menu~=nil or host.saved_searches_job==nil end)
    menu=assert(host._discovery_menu)
    menu:onMenuSelect(menu.item_table[1])
    pump(function() return host.discovery_state and host.discovery_state.keyword=='合成搜索乙' end)
    assert(host.discovery_state.cached and host.discovery_state.keyword=='合成搜索乙'
        and #host.shelf_view.books==1 and host.shelf_view.books[1].bookId=='SYN-BETA',
        'saved search did not reopen the offline result')
    view=assert(host.shelf_view);view.on_search();dialog=assert(view._shelf_popup)
    assert(dialog:getInputText()=='合成搜索乙','offline saved search did not restore its query')
    dialog.buttons[1][1].callback()
    host:closeWeReadUI();host.discovery_state=nil
    if per_page==nil then G_reader_settings:delSetting('items_per_page') else G_reader_settings:saveSetting('items_per_page',per_page) end
    return true
end
