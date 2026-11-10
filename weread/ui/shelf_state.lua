-- Read-only account snapshot. Refresh reuses the existing guarded shelf job.
local Flags=require('weread.lib.shelf_flags')
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _=Util.tr
local M={}
local function scope(host)
    return {account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,session=host._reader_session_gen,
        document=host.ui and host.ui.document,parent=host._book_detail_view}
end
local function current(host,owner)
    return owner.account==host.library_db:accountKey() and owner.epoch==(host.discovery_epoch or 0)
        and owner.session==host._reader_session_gen and owner.document==(host.ui and host.ui.document)
        and owner.parent==host._book_detail_view
end
function M.cancel(host)
    if host._shelf_membership_ui then require('weread.ui.shelf_membership_write').cancel(host) end
    local menu=host._shelf_state_menu;host._shelf_state_menu=nil
    if menu then UIManager:close(menu) end
end
local function text(value)
    if value==true then return _('Yes') elseif value==false then return _('No') end
    return _('Not provided')
end
function M.show(host,id)
    if type(id)~='string' or id=='' or #id>256 or id:find('[%z%c]') then return false end
    M.cancel(host)
    local owner=scope(host)
    local ok,entry=pcall(host.library_db.getShelfStatus,host.library_db,id)
    if not current(host,owner) then return false end
    local book=ok and type(entry)=='table' and entry.book or nil
    local present
    if ok and type(entry)=='table' and type(entry.present)=='boolean' then present=entry.present end
    local items={
        {text=_('In cloud bookshelf'),mandatory=type(present)=='boolean' and text(present) or _('Unknown'),select_enabled=false},
        {text=_('Pinned'),mandatory=text(Flags.display(book,'pinned')),select_enabled=false},
        {text=_('Private reading'),mandatory=text(Flags.display(book,'private')),select_enabled=false},
        {text=_('Finished reading'),mandatory=text(Flags.display(book,'finished')),select_enabled=false},
    }
    if book or type(present)=='boolean' then
        local stamp=entry.cached_at
        local date=type(stamp)=='number' and stamp>=1 and stamp<=4102444800 and os.date('%Y-%m-%d %H:%M',stamp)
        items[#items+1]={text=_('Saved shelf snapshot'),mandatory=date or _('Time unavailable'),select_enabled=false}
    end
    if present==false then
        items[#items+1]={text=_('The last saved bookshelf does not contain this book.'),select_enabled=false}
    elseif present==true and not book then
        items[#items+1]={text=_('Saved status fields are unavailable for this book.'),select_enabled=false}
    elseif not book then
        items[#items+1]={text=_('No saved shelf snapshot for this book.'),select_enabled=false}
    end
    local menu
    if host.shelf_membership and id:match('^[1-9]%d*$') and #id<=20 then
        items[#items+1]={text=_('Change cloud membership'),callback=function()
            if host._shelf_state_menu==menu and current(host,owner) then require('weread.ui.shelf_membership_write').open(host,id) end
        end}
        local pending=host.shelf_membership:pending()
        if pending then
            items[#items+1]={text=_('Check pending bookshelf change'),callback=function()
                if host._shelf_state_menu==menu and current(host,owner) then require('weread.ui.shelf_membership_write').open(host,id,true) end
            end}
        end
    end
    items[#items+1]={text=_('Refresh shelf status'),callback=function()
        if host._shelf_state_menu~=menu or not current(host,owner) then return end
        if host.shelf_refreshing then host:showInfo(_('The bookshelf is already refreshing. Please wait.'));return end
        host:closeWeReadUI()
        local refresh_owner=scope(host)
        local applied=false
        host:refreshBookshelf(nil,{on_loaded=function(saved)
            if applied or not current(host,refresh_owner) then return end
            applied=true
            if saved==false then
                host:showInfo(_('The bookshelf was read, but its status could not be saved. The saved snapshot is unchanged.'))
            else M.show(host,id) end
        end})
    end}
    items[#items+1]={text=_('About shelf status'),callback=function()
        if host._shelf_state_menu~=menu or not current(host,owner) then return end
        host:showInfo(_('These statuses come from the last saved bookshelf. Refresh to see changes from other devices. “Unknown” membership means no complete saved list is available. “Not provided” means a status was not returned. Reading progress and the finished mark are separate.'))
    end}
    menu=host:showList(_('Shelf status'),items);host._shelf_state_menu=menu
    if menu then
        local on_close=menu.onCloseWidget
        menu.onCloseWidget=function(instance,...)
            if host._shelf_state_menu==instance then
                if host._shelf_membership_ui then require('weread.ui.shelf_membership_write').cancel(host) end
                host._shelf_state_menu=nil
            end
            if on_close then return on_close(instance,...) end
        end
    end
    return menu~=nil
end
return M
