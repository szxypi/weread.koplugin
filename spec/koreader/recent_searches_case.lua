-- Real search input, account-local SQLite and offline reopen, synthetic data.
return function(host,mode,_pump,evidence)
    local UI=require('ui/uimanager')
    local H=require('weread.lib.recent_searches')
    local Popup=require('weread.ui.shelf_popup')
    local show_info=host.showInfo
    local keyboard_setting=G_reader_settings:readSetting('virtual_keyboard_enabled')
    G_reader_settings:saveSetting('virtual_keyboard_enabled',true)
    host.showInfo=function() end
    local function home()
        host:closeWeReadUI();host.discovery_state=nil;host:showHome()
        local view=assert(host.shelf_view);view.on_search()
        return view,assert(view._shelf_popup)
    end
    local function open_recent()
        local view,input=home()
        input.buttons[3][1].callback()
        return view,assert(host._discovery_menu,'recent search menu missing')
    end
    if mode=='live' then
        local snapshot,err,account,original=H.list(host);assert(not err and H.clear(host,snapshot,account,original))
        local _,input=home();input:setInputText('  合成搜索乙  ')
        UI:forceRePaint();require('device').screen:shot(evidence..'/recent-search-input.png')
        input.buttons[1][2].callback()
        assert(host.discovery_state and host.discovery_state.keyword=='合成搜索乙')
        _,input=home();input:setInputText('未缓存查询')
        input.buttons[2][2].callback()
        local items=assert(H.list(host)).entries
        assert(#items==2 and items[1].keyword=='未缓存查询' and items[1].public
            and items[2].keyword=='合成搜索乙' and not items[2].public,'search submission did not persist independent history')
        local _,menu=open_recent()
        assert(#menu.item_table==3 and menu.item_table[1].text=='未缓存查询')
        UI:forceRePaint();require('device').screen:shot(evidence..'/recent-search-list.png')
        Popup.close(host.shelf_view)
    else
        local _,menu=open_recent()
        assert(#menu.item_table==3 and menu.item_table[1].text=='未缓存查询'
            and menu.item_table[2].text=='合成搜索乙','history was not recovered in fresh process')
        menu:onMenuSelect(menu.item_table[2])
        assert(host.discovery_state and host.discovery_state.cached and host.discovery_state.keyword=='合成搜索乙',
            'recent search did not use cached result offline')
        _,menu=open_recent()
        local account_key=host.library_db.accountKey
        host.library_db.accountKey=function() return string.rep('c',20) end
        assert(#assert(H.list(host)).entries==0,'recent search leaked across accounts')
        local stale=menu.item_table[1].callback;stale()
        host.library_db.accountKey=account_key
        assert(host._discovery_menu==menu,'stale account action changed the menu')
        menu:onMenuHold(menu.item_table[1]);local confirm=assert(UI:getTopmostVisibleWidget());confirm.cancel_callback()
        assert(#H.list(host).entries==2,'cancelled removal changed history')
        menu:onMenuHold(menu.item_table[1]);confirm=assert(UI:getTopmostVisibleWidget());confirm.ok_callback()
        menu=assert(host._discovery_menu);assert(#menu.item_table==2 and #H.list(host).entries==1,'removal failed')
        menu:onMenuSelect(menu.item_table[2]);confirm=assert(UI:getTopmostVisibleWidget());confirm.ok_callback()
        assert(#H.list(host).entries==0,'clear failed')
    end
    host:closeWeReadUI();host.discovery_state=nil;host.showInfo=show_info
    if keyboard_setting==nil then G_reader_settings:delSetting('virtual_keyboard_enabled')
    else G_reader_settings:saveSetting('virtual_keyboard_enabled',keyboard_setting) end
    return true
end
