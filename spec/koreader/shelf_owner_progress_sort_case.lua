-- Private account data stays in the existing tmpfs profile; no extra reads.
return function(plugin,pump)
    local Flags=require('weread.lib.shelf_flags')
    local Identity=require('weread.lib.shelf_snapshot')
    local Data=require('weread.lib.shelf_progress')
    local original_sort=plugin.settings:get('shelf').sort_order
    local original_group,original_multi,original_filters=plugin.shelf_group_key,plugin.shelf_multi_groups,plugin.shelf_filters
    local cover_fetch,progress_fetch=plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress
    plugin:cancelShelfCovers();plugin:cancelShelfProgress()
    plugin.fetchVisibleShelfCovers=function() end
    plugin.refreshVisibleShelfProgress=function() end
    plugin.shelf_group_key,plugin.shelf_multi_groups,plugin.shelf_filters=nil,{},{}
    local books=assert(plugin.shelf_regular);assert(#books>0)
    local ids,positions={},{}
    for index,book in ipairs(books) do
        local id=Identity.persisted_id(book);positions[book]=index
        if id and Data.book_id(id) then ids[#ids+1]=id end
    end
    local snapshots=plugin.library_db:getShelfProgress(ids)
    local saved=plugin.settings:get('books',{})
    -- The isolated profile must contain no local pending progress: the cached
    -- cloud snapshot is the independent reference for this particular check.
    for _,value in pairs(saved) do assert(type(value)~='table' or value.pending_upload_position==nil) end
    local known=0
    for _,id in ipairs(ids) do
        local snapshot=snapshots[id]
        if snapshot and type(snapshot.percent)=='number' then known=known+1 end
    end
    assert(known>0)
    plugin:showShelfView('books',nil,plugin.shelf_view,{page=1})
    for choice=8,9 do
        local old=assert(plugin.shelf_view);old.on_sort()
        local dialog=assert(old._shelf_popup);assert(dialog.buttons[choice] and dialog.buttons[choice][1])
        dialog.buttons[choice][1].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=old end)
        local view=plugin.shelf_view;assert(#view.books==#books)
        local seen,last_pinned,last_percent,last_index={},true,nil,nil
        for _,book in ipairs(view.books) do
            local index=assert(positions[book]);assert(not seen[book]);seen[book]=true
            local pinned=Flags.display(book,'pinned')==true
            if pinned then assert(last_pinned) end
            local id=Identity.persisted_id(book)
            local snapshot=id and snapshots[id]
            local percent=snapshot and snapshot.percent or nil
            assert(book._shelf_progress==percent and not book._shelf_progress_local)
            if pinned~=last_pinned then last_percent,last_index=nil,nil end
            if last_index then
                if last_percent==nil then assert(percent==nil)
                elseif percent~=nil then
                    if percent==last_percent then assert(index>last_index)
                    elseif choice==8 then assert(last_percent>percent) else assert(last_percent<percent) end
                end
            end
            last_pinned,last_percent,last_index=pinned,percent,index
        end
        require('ui/uimanager'):forceRePaint()
    end
    local shelf=plugin.settings:get('shelf');shelf.sort_order=original_sort
    plugin.settings:set('shelf',shelf);plugin.settings:flush()
    plugin.shelf_group_key,plugin.shelf_multi_groups,plugin.shelf_filters=original_group,original_multi,original_filters
    plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress=cover_fetch,progress_fetch
    return true
end
