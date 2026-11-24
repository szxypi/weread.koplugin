-- Read-only checks against the owner's existing isolated shelf cache.
-- Private titles, IDs and progress values never leave the tmpfs profile.
return function(plugin,pump)
    local Flags=require('weread.lib.shelf_flags')
    local Identity=require('weread.lib.shelf_snapshot')
    local Data=require('weread.lib.shelf_progress')
    local old_filters,old_notice=plugin.shelf_filters,plugin.showTransientInfo
    local old_group,old_multi=plugin.shelf_group_key,plugin.shelf_multi_groups
    local shelf=plugin.settings:get('shelf')
    local old_reading,old_download=shelf.filter_reading,shelf.filter_download
    local cover_fetch,progress_fetch=plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress
    plugin:cancelShelfCovers();plugin:cancelShelfProgress()
    plugin.fetchVisibleShelfCovers=function() end;plugin.refreshVisibleShelfProgress=function() end
    plugin.showTransientInfo=function() end
    plugin.shelf_group_key,plugin.shelf_multi_groups,plugin.shelf_filters=nil,{},{}
    local books=assert(plugin.shelf_regular);assert(#books>0)
    local ids={}
    for _,book in ipairs(books) do
        local id=Identity.persisted_id(book)
        if id and Data.book_id(id) then ids[#ids+1]=id end
    end
    local snapshots=plugin.library_db:getShelfProgress(ids)
    local saved=plugin.settings:get('books',{})
    for _,record in pairs(saved) do assert(type(record)~='table' or record.pending_upload_position==nil) end
    local known=0
    local function expected(book,positive)
        local id=Identity.persisted_id(book)
        local row=id and snapshots[id]
        if Flags.display(book,'finished')~=false or type(row)~='table' then return false end
        local value,exact=row.percent,row.exact_percent
        if type(value)~='number' or value~=value or value<0 or value>100 then return false end
        value=math.floor(value)
        if type(exact)~='number' or exact~=exact or exact<0 or exact>100 or math.floor(exact)~=value then
            exact=value>0 and value or nil
        end
        if exact==nil then return false end
        return positive and exact>0 or not positive and exact==0
    end
    for _,book in ipairs(books) do if expected(book,true) or expected(book,false) then known=known+1 end end
    assert(known>0,'no valid account progress available for filter verification')
    plugin:showShelfView('books',nil,plugin.shelf_view,{page=1})
    for choice=4,5 do
        local old=assert(plugin.shelf_view);old.on_filter()
        local dialog=assert(old._shelf_popup);assert(dialog.buttons[choice] and dialog.buttons[choice][1])
        dialog.buttons[choice][1].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=old end)
        local view=plugin.shelf_view;local selected={}
        for _,book in ipairs(view.books) do assert(not selected[book] and expected(book,choice==5));selected[book]=true end
        for _,book in ipairs(books) do assert((selected[book]==true)==expected(book,choice==5)) end
        require('ui/uimanager'):forceRePaint()
    end
    shelf=plugin.settings:get('shelf');shelf.filter_reading=old_reading;shelf.filter_download=old_download
    plugin.settings:set('shelf',shelf);plugin.settings:flush()
    plugin.shelf_group_key,plugin.shelf_multi_groups,plugin.shelf_filters=old_group,old_multi,old_filters
    plugin.fetchVisibleShelfCovers,plugin.refreshVisibleShelfProgress=cover_fetch,progress_fetch
    plugin.showTransientInfo=old_notice
    return true
end
