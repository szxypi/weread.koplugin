-- Native deferred buttons and owned dialogs, on the actual FileManager host.
-- The dispatch boundary is observed; normal HTTP search is covered separately.
return function(plugin,evidence)
    assert(require('apps/filemanager/filemanager').instance.weread==plugin)
    local UI,Screen=require('ui/uimanager'),require('device').screen
    local tr=require('weread.lib.plugin_util').tr
    local original_load=plugin.loadDiscoveryBatch
    local dispatched,cases,painted=0,0,0
    local function drain()
        for _tick_index=1,5 do UI:setInputTimeout(0);UI:handleInput();require('socket').sleep(.005) end
    end
    local function paint()
        UI:forceRePaint();painted=painted+1
    end
    local function open(tab)
        plugin:closeWeReadUI()
        if tab=='home' then plugin:showHome() else plugin:showBookstore() end
        paint();return assert(plugin.shelf_view)
    end
    local function change(event)
        if event=='closed' then plugin:closeWeReadUI()
        elseif event=='replaced' then plugin:showBookstore()
        else plugin._reader_session_gen=(plugin._reader_session_gen or 0)+1 end
    end
    local function item(menu,label)
        for _item_index,row in ipairs(menu.item_table) do if row.text:find(tr(label),1,true) then return row end end
        error('synthetic native menu item missing')
    end
    plugin.loadDiscoveryBatch=function(self,kind,keyword,cursor)
        dispatched=dispatched+1;assert(kind=='search' and keyword=='合成查询' and cursor==0)
        self:closeWeReadUI()
    end
    for _tab_index,tab in ipairs({'home','store'}) do
        for _event_index,event in ipairs({'closed','replaced','session'}) do
            local view=open(tab)
            local target=tab=='home' and 3 or 1
            view._navigation_buttons[target].callback()
            change(event);local active=plugin.shelf_view;drain()
            assert(plugin.shelf_view==active,'deferred old navigation changed the active view');cases=cases+1
            view=open(tab);view._header_buttons[3].callback();drain()
            local dialog=assert(view._shelf_popup);dialog:setInputText('合成查询')
            local submit=dialog.buttons[1][2].callback
            change(event);active=plugin.shelf_view;local before=dispatched
            dialog.getInputText=function() error('stale native input accessed') end
            submit();drain()
            assert(dispatched==before and plugin.shelf_view==active,'stale native search dispatched');cases=cases+1
        end
        for _choice_index,choice in ipairs({'cancel','search'}) do
            local view=open(tab);view.on_search();local dialog=assert(view._shelf_popup)
            local books=view.books
            plugin:fetchVisibleShelfCovers(view,books,{on_redraw=function() end})
            -- Invoke the normal page callback while the native dialog is open.
            view.on_page_changed(view.page)
            assert(plugin.shelf_view==view and view._shelf_popup==dialog and view._shelf_redraw)
            paint();Screen:shot(evidence..'/portal-'..tab..'-search.png')
            local before=dispatched
            if choice=='cancel' then dialog.buttons[1][1].callback()
            else dialog:setInputText('合成查询');dialog.buttons[1][2].callback() end
            drain()
            if choice=='cancel' then assert(plugin.shelf_view and plugin.shelf_view~=view and dispatched==before)
            else assert(not plugin.shelf_view and dispatched==before+1) end
            cases=cases+1
        end
        local view=open(tab)
        local data={loaded_at=os.time(),ranks={{id='rising',title='合成榜单',rank=true,children={}}},categories={}}
        plugin:showDiscoveryCategoryPicker(data);local menu=assert(plugin._discovery_menu)
        local choose=menu.item_table[1].sub_item_table[1].callback
        view.on_page_changed(view.page);assert(view._shelf_popup==menu and view._shelf_redraw)
        paint();plugin:showBookstore();local replacement=plugin.shelf_view
        choose();drain()
        assert(plugin.shelf_view==replacement and not plugin._discovery_menu and not view._shelf_popup);cases=cases+1
        view=open(tab)
        local stale=view._navigation_buttons[tab=='home' and 3 or 1].callback
        local book=assert(plugin.library_db:getShelf()[1]);plugin:showBookMenu(book)
        plugin._book_detail_view:onClose();drain()
        replacement=assert(plugin.shelf_view)
        assert(replacement~=view and replacement._discovery_current())
        stale();drain();assert(plugin.shelf_view==replacement);cases=cases+1
    end
    for _event_index,event in ipairs({'closed','replaced','session'}) do
        local view=open('home');view.settings_button.callback();drain()
        local menu=assert(plugin._home_controls_menu);local callback=item(menu,'Download book images').callback
        local before=plugin.settings:get('cache').download_book_images
        change(event);local active=plugin.shelf_view;callback();drain()
        assert(plugin.settings:get('cache').download_book_images==before and plugin.shelf_view==active);cases=cases+1
        view=open('home');plugin:showHomeQuickSettings();menu=plugin._home_controls_menu
        local cache=plugin.settings:get('cache');cache.auto_prefetch_next_chapter=false;plugin.settings:set('cache',cache);plugin.settings:flush()
        menu:onMenuSelect(item(menu,'Automatically prefetch next chapter'))
        local box=assert(plugin._home_prefetch_confirmation)
        assert(view._shelf_popup==box);paint()
        change(event);active=plugin.shelf_view;box.ok_callback();drain()
        assert(not plugin.settings:get('cache').auto_prefetch_next_chapter and plugin.shelf_view==active);cases=cases+1
    end
    open('home');plugin:showHomeQuickSettings();local menu=plugin._home_controls_menu
    local before=plugin.settings:get('cache').download_book_images
    menu:onMenuSelect(item(menu,'Download book images'));drain()
    assert(plugin.settings:get('cache').download_book_images~=before and plugin._home_controls_menu)
    cases=cases+1
    plugin._home_controls_menu:onMenuSelect(item(plugin._home_controls_menu,'Automatically prefetch next chapter'))
    local box=assert(plugin._home_prefetch_confirmation);box.ok_callback();drain()
    assert(plugin.settings:get('cache').auto_prefetch_next_chapter and not plugin._home_prefetch_confirmation)
    cases=cases+1
    plugin:closeWeReadUI();plugin:applyShelfSnapshot(plugin.library_db:getShelf(),plugin.library_db:getShelfArchives())
    plugin:showShelfView('books');local shelf=assert(plugin.shelf_view)
    plugin:showBookMenu(assert(shelf.books[1]));plugin._book_detail_view:onClose();drain()
    assert(plugin.shelf_view~=shelf and not plugin._book_detail_view)
    local reopened=plugin.shelf_view;reopened:showSourceMenu();assert(reopened._shelf_popup)
    UI:close(reopened._shelf_popup);cases=cases+1
    plugin:closeWeReadUI();plugin.loadDiscoveryBatch=original_load
    return {cases=cases,painted_views=painted,intercepted_searches=dispatched,pluginloader_filemanager=true}
end
