-- Actual native shelf controls over private, file-backed owner data.
-- The caller disables screenshots and restricts all account network routes.
return function(plugin, pump)
    local UI=require('ui/uimanager')
    local Search=require('weread.lib.shelf_search')
    local trim=require('weread.lib.search_query').trim
    local Flags=require('weread.lib.shelf_flags')
    local original_sort=plugin.settings:get('shelf').sort_order
    local original_group,original_multi=plugin.shelf_group_key,plugin.shelf_multi_groups
    local cover_fetch,progress_fetch=plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress
    plugin:cancelShelfCovers();plugin:cancelShelfProgress()
    plugin.fetchVisibleShelfCovers=function() end
    plugin.refreshVisibleShelfProgress=function() end
    plugin.shelf_group_key,plugin.shelf_multi_groups=nil,{}
    local books=assert(plugin.shelf_regular);assert(#books>0)
    local positions={};for index,book in ipairs(books) do positions[book]=index end
    plugin:showShelfView('books',nil,plugin.shelf_view,{page=1})
    local known=0
    for choice=6,7 do
        local old=assert(plugin.shelf_view);old.on_sort()
        local dialog=assert(old._shelf_popup);assert(dialog.buttons[choice] and dialog.buttons[choice][1])
        dialog.buttons[choice][1].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=old end)
        local view=plugin.shelf_view;assert(#view.books==#books)
        local seen,last_pinned,last_key,last_index={},true,nil,nil
        for _,book in ipairs(view.books) do
            local index=assert(positions[book]);assert(not seen[book]);seen[book]=true
            local pinned=Flags.display(book,'pinned')==true
            if pinned then assert(last_pinned) end
            local author=trim(book.author);if author=='' then author=trim(book.authors) end
            local key=author~='' and Search.prepare(author) or nil
            if key then known=known+1 end
            if pinned~=last_pinned then last_key,last_index=nil,nil end
            if last_index then
                if last_key==nil then assert(key==nil)
                elseif key~=nil then
                    if key==last_key then assert(index>last_index)
                    elseif choice==6 then assert(last_key<key) else assert(last_key>key) end
                end
            end
            last_pinned,last_key,last_index=pinned,key,index
        end
        UI:forceRePaint()
    end
    assert(known>0)
    local shelf=plugin.settings:get('shelf');shelf.sort_order=original_sort
    plugin.settings:set('shelf',shelf);plugin.settings:flush()
    plugin.shelf_group_key,plugin.shelf_multi_groups=original_group,original_multi
    plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress=cover_fetch,progress_fetch
    return true
end
