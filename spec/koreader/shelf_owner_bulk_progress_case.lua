-- Real menu and account-scoped SQLite; transport is guarded by the caller.
return function(plugin,mode,counters)
    local UI=require('ui/uimanager');local socket=require('socket')
    local Data=require('weread.lib.shelf_progress')
    local Identity=require('weread.lib.shelf_snapshot')
    local access=assert(Data.selection(plugin.settings))
    local ids,seen,skipped={}, {},0
    for _,book in ipairs(assert(plugin.shelf_regular)) do
        local id=Identity.persisted_id(book)
        if id and Data.supports(id,access) and not seen[id] then ids[#ids+1]=id;seen[id]=true
        else skipped=skipped+1 end
    end
    assert(#ids>0 and #ids<=160)
    local report={eligible=#ids,saved=0,skipped=skipped,menu_started=false,cache_verified=false}
    local function check_cache(expected)
        local snapshots=assert(plugin.library_db:getShelfProgress(ids));local count=0
        for _,id in ipairs(ids) do
            local value=snapshots[id]
            if value then
                assert(value.book_id==id and value.source=='web' and type(value.fetched_at)=='number'
                    and (type(value.percent)=='number' and value.percent>=0 and value.percent<=100
                        or value.unavailable==true and value.percent==nil))
                count=count+1
            end
        end
        assert(count==expected);return count
    end
    local function pump(predicate,seconds)
        local deadline=socket.gettime()+seconds
        while not predicate() do
            assert(socket.gettime()<deadline,'bulk update deadline')
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    if mode=='live' then
        assert(check_cache(0)==0)
        local cover_fetch,progress_fetch=plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress
        local transient=plugin.showTransientInfo
        plugin.fetchVisibleShelfCovers=function() end;plugin.refreshVisibleShelfProgress=function() end
        plugin.showTransientInfo=function() end
        plugin.shelf_group_key=nil;plugin.shelf_multi_groups={};plugin.shelf_filters={}
        plugin:showShelfView('books',nil,plugin.shelf_view,{page=1})
        local view=assert(plugin.shelf_view);view.on_sort();local menu=assert(view._shelf_popup)
        local action
        for _,row in ipairs(menu.buttons) do for _,button in ipairs(row) do
            if button.text==require('weread.lib.i18n').tr('Update all bookshelf progress') then action=button end
        end end
        assert(action);action.callback()
        pump(function() return plugin.shelf_progress_all_context~=nil end,10)
        local job=assert(plugin.shelf_progress_all_context)
        assert(#job.ids==#ids and job.skipped==skipped and job.dialog.progress_max==#ids)
        report.menu_started=true
        pump(function() return not plugin.shelf_progress_all_context
            and (not plugin.shelf_progress_all_worker or not plugin.shelf_progress_all_worker:busy()) end,300)
        assert(job.done==#ids and counters()==#ids)
        report.saved=check_cache(#ids);report.cache_verified=true
        plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress=cover_fetch,progress_fetch
        plugin.showTransientInfo=transient
    else
        report.saved=check_cache(#ids);report.cache_verified=true
        local reads,denied=counters();assert(reads==0 and denied==0)
    end
    return report
end
