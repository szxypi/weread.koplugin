-- Real thumbnail children and progress HTTP must not interrupt an open selector.
return function(host,response,cover,evidence)
    assert(host.settings.mock_endpoint,'synthetic-only popup regression')
    local UI=require('ui/uimanager')
    local socket=require('socket')
    local cache=host:getShelfCoverCache()
    local online,connected=host.isNetworkOnline,host.isNetworkConnected
    local original_group=host.shelf_group_key
    local original={};for key,value in pairs(host.settings:get('shelf')) do original[key]=value end
    local function pump(predicate)
        local deadline=socket.gettime()+20
        while not predicate() do
            assert(socket.gettime()<deadline,'popup background deadline')
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    local function show(online_now,force)
        host:closeWeReadUI()
        host.isNetworkOnline=function() return online_now end;host.isNetworkConnected=host.isNetworkOnline
        local settings=host.settings:get('shelf');settings.view_mode='cover';settings.paginated=true;settings.sort_order='default'
        host.settings:set('shelf',settings);host.settings:flush()
        host:applyShelfSnapshot(response.books,response.archive)
        host:showShelfView('books',nil,nil,{refresh_progress=force})
        return assert(host.shelf_view)
    end
    for _action_index,action in ipairs({'cancel','select'}) do
        local view=show(false,false)
        local book=assert(view:getVisibleBooks()[1]);assert(cache:store(book,cover))
        -- The shared URL is a valid legacy source, converted by the normal C
        -- thumbnail worker. Only this isolated mock profile is changed.
        host:showShelfView('books',nil,view);view=host.shelf_view
        UI:forceRePaint();view:showSourceMenu();local picker=assert(view._shelf_popup)
        local path=assert(cache:pathFor(book));assert(path:sub(1,#host.settings.data_dir+1)==host.settings.data_dir..'/')
        local source=cache.dir..'/'..cache:key(book)..'.png'
        local file=assert(io.open(source,'wb'));assert(file:write(cover));file:close();assert(os.remove(path))
        host:fetchVisibleShelfCovers(view,view.books,{mode='books',prepared_books=view.books,prepared_accounts=view.accounts})
        local job=assert(host.shelf_cover_job);local pid=assert(job.pid)
        pump(function() return not host.shelf_cover_job and not host.shelf_cover_pending end)
        assert(require('ffi/util').isSubProcessDone(pid))
        assert(host.shelf_view==view and view._shelf_popup==picker and view._shelf_redraw,'thumbnail result interrupted selector')
        UI:forceRePaint();require('device').screen:shot(evidence..'/popup-background-'..action..'.png')
        if action=='cancel' then
            UI:close(picker);pump(function() return host.shelf_view~=view end)
            assert(host.shelf_group_key==nil and host:getShelfCoverCache():pathFor(book))
        else
            local group=assert(host.shelf_groups[1]);picker:onMenuSelect(picker.item_table[2])
            pump(function() return host.shelf_view~=view end)
            assert(host.shelf_group_key==group.key)
            local selected=host.shelf_view
            for _i=1,5 do UI:setInputTimeout(0);UI:handleInput() end
            assert(host.shelf_view==selected and selected.group_key==group.key,'thumbnail redraw overwrote group selection')
        end
    end
    local view=show(true,true)
    local worker=assert(host.shelf_progress_worker);assert(worker.job and worker.job.pid)
    view:showSourceMenu();local picker=assert(view._shelf_popup)
    pump(function()
        local context=host.shelf_progress_context
        return not context or not context.request and not context.renewing
    end)
    assert(host.shelf_view==view and view._shelf_popup==picker and view._shelf_redraw,'progress result interrupted selector')
    UI:close(picker);pump(function() return host.shelf_view~=view end)
    host:closeWeReadUI()
    assert(host.library_db:cacheShelf(response.books,response.archive))
    host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
    host:showHome()
    view=assert(host.shelf_view)
    local book=assert(view:getVisibleBooks()[1]);assert(cache:store(book,cover))
    host:showHome();view=host.shelf_view
    local path=assert(cache:pathFor(book));local source=cache.dir..'/'..cache:key(book)..'.png'
    local file=assert(io.open(source,'wb'));assert(file:write(cover));file:close();assert(os.remove(path))
    host:showHome();view=host.shelf_view
    local job=assert(host.shelf_cover_job);local pid=assert(job.pid)
    view.on_search();local search=assert(view._shelf_popup)
    pump(function() return not host.shelf_cover_job and not host.shelf_cover_pending end)
    assert(require('ffi/util').isSubProcessDone(pid))
    assert(host.shelf_view==view and view._shelf_popup==search and view._shelf_redraw,'home thumbnail result interrupted search')
    UI:forceRePaint();require('device').screen:shot(evidence..'/portal-home-thumbnail-search.png')
    search.buttons[1][1].callback();pump(function() return host.shelf_view~=view end)
    assert(cache:pathFor(book),'home search cancel lost thumbnail')
    host:closeWeReadUI()
    host.isNetworkOnline=function() return true end;host.isNetworkConnected=host.isNetworkOnline
    host:showHome(true);view=host.shelf_view
    worker=assert(host.shelf_progress_worker);assert(worker.job and worker.job.pid)
    host:showHomeQuickSettings();local quick=assert(host._home_controls_menu)
    pump(function()
        local context=host.shelf_progress_context
        return not context or not context.request and not context.renewing
    end)
    assert(host.shelf_view==view and view._shelf_popup==quick and view._shelf_redraw,'home HTTP progress interrupted quick settings')
    UI:forceRePaint();require('device').screen:shot(evidence..'/portal-home-progress-settings.png')
    quick:onCloseAllMenus();pump(function() return host.shelf_view~=view end)
    host:closeWeReadUI();host.settings:set('shelf',original);host.settings:flush()
    host.isNetworkOnline,host.isNetworkConnected=online,connected
    host.shelf_group_key=original_group
    print('PASS: native selector retained through thumbnail children and HTTP progress; cancel refreshes, selection wins')
    print('PASS: native home search and quick settings retained through thumbnail children and HTTP progress')
end
