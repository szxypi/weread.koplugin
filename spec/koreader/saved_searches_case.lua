-- Real offline search-history menu and per-account SQLite, synthetic data only.
return function(host,mode,pump,evidence)
    local Cache=require('weread.lib.discovery_cache')
    local cache=Cache:new(host.library_db,host.client)
    local Util=require('weread.lib.plugin_util')
    local public_label=Util.T(Util.tr('Public search: %1'),'合成搜索乙')
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
    assert(#menu.item_table==12 and menu.item_table[1].text==(mode=='live' and '合成搜索乙' or public_label)
        and menu.item_table[2].text==(mode=='live' and '合成搜索甲' or '合成搜索乙'),
        'saved searches are not in most recently saved order')
    assert(menu.page_num>1,'saved search pagination fixture did not paginate')
    require('ui/uimanager'):forceRePaint()
    require('device').screen:shot(evidence..'/saved-searches.png')
    menu:onGotoPage(menu.page_num);assert(menu.page==menu.page_num)
    menu:onMenuSelect(menu.item_table[#menu.item_table])
    pump(function() return host.discovery_state and host.discovery_state.kind=='search' end)
    assert(host.discovery_state.cached and host.discovery_state.keyword=='合成查询 1'
        and host.shelf_view.books[1].bookId=='SYN-1','older saved search did not reopen')
    view=assert(host.shelf_view);view.on_search();dialog=assert(view._shelf_popup);dialog.buttons[1][3].callback()
    pump(function() return host._discovery_menu~=nil or host.saved_searches_job==nil end)
    menu=assert(host._discovery_menu)
    menu:onMenuSelect(menu.item_table[mode=='live' and 1 or 2])
    pump(function() return host.discovery_state and host.discovery_state.keyword=='合成搜索乙' end)
    assert(host.discovery_state.cached and host.discovery_state.keyword=='合成搜索乙'
        and #host.shelf_view.books==1 and host.shelf_view.books[1].bookId=='SYN-BETA',
        'saved search did not reopen the offline result')
    view=assert(host.shelf_view);view.on_search();dialog=assert(view._shelf_popup)
    assert(dialog:getInputText()=='合成搜索乙','offline saved search did not restore its query')
    if mode=='live' then
        dialog.buttons[1][3].callback()
        pump(function() return host._discovery_menu~=nil or host.saved_searches_job==nil end)
        menu=assert(host._discovery_menu);local target
        for _,row in ipairs(menu.item_table) do if row.text=='合成查询 3' then target=row end end
        assert(target);menu:onMenuHold(target)
        local confirm=assert(require('ui/uimanager'):getTopmostVisibleWidget())
        assert(confirm.ok_callback and confirm.cancel_callback)
        confirm.cancel_callback();assert(cache:read{kind='search',keyword='合成查询 3'})
        menu:onMenuHold(target);confirm=assert(require('ui/uimanager'):getTopmostVisibleWidget());confirm.ok_callback()
        pump(function() return host._discovery_menu and host._discovery_menu~=menu and not host.saved_searches_job end)
        menu=host._discovery_menu
        assert(#menu.item_table==11 and not cache:read{kind='search',keyword='合成查询 3'})
        assert(cache:read{kind='search',keyword='合成搜索乙'} and cache:read{kind='search',keyword='合成查询 1'})
        require('ui/uimanager'):forceRePaint();require('device').screen:shot(evidence..'/saved-searches-removed.png')
        local public=state('合成搜索乙','SYN-PUBLIC-BETA');public.source_kind='public'
        assert(cache:write(public))
    else
        dialog.buttons[2][2].callback()
        pump(function() return host.discovery_state.source_kind=='public' end)
        assert(host.discovery_state.cached and host.shelf_view.books[1].bookId=='SYN-PUBLIC-BETA',
            'explicit public search restored the ordinary snapshot')
        view=assert(host.shelf_view);view.on_search();dialog=assert(view._shelf_popup);dialog.buttons[1][3].callback()
        pump(function() return host._discovery_menu~=nil or host.saved_searches_job==nil end)
        menu=assert(host._discovery_menu)
        assert(menu.item_table[1].text==public_label)
        menu:onMenuSelect(menu.item_table[1])
        assert(host.discovery_state.source_kind=='public' and host.shelf_view.books[1].bookId=='SYN-PUBLIC-BETA',
            'saved public row opened the ordinary snapshot')
        view=assert(host.shelf_view);view.on_search();dialog=assert(view._shelf_popup);dialog.buttons[1][3].callback()
        pump(function() return host._discovery_menu~=nil or host.saved_searches_job==nil end)
        menu=assert(host._discovery_menu);menu:onMenuHold(menu.item_table[1])
        assert(require('ui/uimanager'):getTopmostVisibleWidget().ok_callback)()
        pump(function() return host._discovery_menu and host._discovery_menu~=menu and not host.saved_searches_job end)
        assert(cache:read({kind='search',keyword='合成搜索乙'},0).books[1].bookId=='SYN-BETA'
            and not cache:read({kind='search',keyword='合成搜索乙',public_only=true},0),'deletion crossed saved sources')
        assert(not cache:read{kind='search',keyword='合成查询 3'},'removed search returned after restart')
        local Recent=require('weread.lib.recent_searches')
        local recent,err,account,original=Recent.list(host)
        assert(not err and recent.entries[1].keyword=='合成搜索乙' and recent.entries[1].public)
        assert(Recent.remove(host,recent,account,original,1))
    end
    host:closeWeReadUI();host.discovery_state=nil
    if per_page==nil then G_reader_settings:delSetting('items_per_page') else G_reader_settings:saveSetting('items_per_page',per_page) end
    return true
end
