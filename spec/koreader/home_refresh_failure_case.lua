-- Synthetic refresh results through the real FileManager, home and shelf UI.
return function(host,pump)
    local tr=require('weread.lib.i18n').tr
    local saved={cache=host.library_db.cacheShelf,fetch=host.client.get_shelf,login=host.requireShelfLogin,
        connected=host.isNetworkConnected,worker=host.shelf_refresh_worker,notice=host.showTransientInfo,
        progress=host.prepareShelfProgress,home=host.settings:get('home')}
    local old_books=assert(host.library_db:getShelf());local old_archives=assert(host.library_db:getShelfArchives())
    local fresh={{bookId='SYN-HOME-FRESH',title='合成刷新书籍',author='合成作者',readUpdateTime=2000000000}}
    local notices,save_result={},false
    host.requireShelfLogin=function() return true end
    host.isNetworkConnected=function() return true end
    host.client.get_shelf=function() return {books=fresh,archive={},_shelf_source='native'} end
    host.shelf_refresh_worker={start=function(_self,task,callback) callback(task());return true end,cancel=function() end}
    host.prepareShelfProgress=false
    host.showTransientInfo=function(_self,message) notices[#notices+1]=message end
    host.library_db.cacheShelf=function(self,books,archives)
        if not save_result then return false end
        return saved.cache(self,books,archives)
    end
    local home_settings={};for key,value in pairs(saved.home or {}) do home_settings[key]=value end
    home_settings.show_shortcuts=true;home_settings.shortcuts={'refresh'};host.settings:set('home',home_settings)
    local cases=0
    for _,entry in ipairs({'header','shortcut','shelf'}) do
        assert(saved.cache(host.library_db,old_books,old_archives));host:applyShelfSnapshot(old_books,old_archives)
        notices={};save_result=false
        host:closeWeReadUI()
        if entry=='shelf' then host:showBookshelf() else host:showHome() end
        local prior=assert(host.shelf_view)
        if entry=='header' or entry=='shelf' then prior.on_refresh()
        else assert(prior.actions and prior.actions[1]);prior.actions[1].callback() end
        pump(function() return host.shelf_view and host.shelf_view~=prior and not host.shelf_refreshing end)
        assert(#host.shelf_view.books==1 and host.shelf_view.books[1].bookId=='SYN-HOME-FRESH',
            'fresh shelf disappeared after failed cache save')
        assert(#notices==1 and notices[1]==tr('Could not save the bookshelf for offline use. The current list is still available.'),
            'failed cache save did not show the correct notice')
        local stored=host.library_db:getShelf()
        assert(#stored==#old_books and stored[1].bookId==old_books[1].bookId,'failed cache save replaced old shelf')
        host:closeWeReadUI();host:showBookshelf()
        assert(#host.shelf_view.books==1 and host.shelf_view.books[1].bookId=='SYN-HOME-FRESH',
            'unsaved shelf vanished after navigating to bookshelf')
        host:closeWeReadUI();host:showHome()
        assert(#host.shelf_view.books==1 and host.shelf_view.books[1].bookId=='SYN-HOME-FRESH',
            'unsaved shelf vanished after returning home')
        local unsaved=assert(host._volatile_shelf).snapshot
        local options=host.settings:get('shelf');local old_source=options.source
        options.source='gateway';host.settings:set('shelf',options)
        host:closeWeReadUI();host:showHome()
        assert(host.shelf_view.books[1].bookId~='SYN-HOME-FRESH' and not host._volatile_shelf,
            'unsaved shelf crossed a source change')
        options.source=old_source;host.settings:set('shelf',options)
        assert(require('weread.lib.volatile_shelf').remember(host,unsaved,{_shelf_source='native'}))
        host:applyShelfSnapshot(old_books,old_archives)
        assert(not host._volatile_shelf,'new shelf snapshot did not invalidate unsaved shelf')
        require('ui/uimanager'):forceRePaint();cases=cases+1
    end
    assert(saved.cache(host.library_db,old_books,old_archives));host:applyShelfSnapshot(old_books,old_archives)
    notices={};save_result=true
    host:closeWeReadUI();host:showHome();local prior=assert(host.shelf_view);prior.on_refresh()
    pump(function() return host.shelf_view and host.shelf_view~=prior and not host.shelf_refreshing end)
    assert(#host.shelf_view.books==1 and host.shelf_view.books[1].bookId=='SYN-HOME-FRESH')
    local stored=host.library_db:getShelf();assert(#stored==1 and stored[1].bookId=='SYN-HOME-FRESH' and #notices==0 and not host._volatile_shelf)
    cases=cases+1
    host:closeWeReadUI();assert(saved.cache(host.library_db,old_books,old_archives))
    host.library_db.cacheShelf=saved.cache;host.client.get_shelf=saved.fetch;host.requireShelfLogin=saved.login
    host.isNetworkConnected=saved.connected;host.shelf_refresh_worker=saved.worker;host.showTransientInfo=saved.notice
    host.prepareShelfProgress=saved.progress;host.settings:set('home',saved.home)
    return cases
end
