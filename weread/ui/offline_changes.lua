-- Discover queued changes, including books which are not yet on the shelf.
-- Opening this list only reads local state; actions go through shelf status.
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function context(host)
    return {account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,
        session=host._reader_session_gen,document=host.ui and host.ui.document,
        parent=host._book_detail_view,owner=host.shelf_view}
end
local function current(host,ctx)
    return ctx.account and ctx.account==host.library_db:accountKey() and ctx.epoch==(host.discovery_epoch or 0)
        and ctx.session==host._reader_session_gen and ctx.document==(host.ui and host.ui.document)
        and ctx.parent==host._book_detail_view and ctx.owner==host.shelf_view
        and (not ctx.owner or not ctx.owner._shelf_closed)
end
function M.cancel(host)
    local menu=host._offline_changes_menu;host._offline_changes_menu=nil
    if not menu then return end
    local owner=menu._offline_owner
    if owner and Popup.current(owner,menu) then Popup.close(owner) else UI:close(menu) end
end
local function title_map(host)
    local titles={}
    local function add(book)
        if type(book)~='table' then return end
        local id=book.book_id or book.bookId
        local title=book.title
        if (type(id)=='string' or type(id)=='number') and type(title)=='string' and title~=''
            and #title<=1024 and not title:find('[%z%c]') then titles[tostring(id)]=title end
    end
    for _,list in ipairs({host.shelf_regular or {},host.shelf_mp or {},
        type(host.discovery_state)=='table' and host.discovery_state.books or {}}) do
        if type(list)=='table' then for _,book in ipairs(list) do add(book) end end
    end
    if not host.shelf_regular and host.library_db.getShelf then
        local ok_shelf,shelf=pcall(host.library_db.getShelf,host.library_db)
        if ok_shelf and type(shelf)=='table' then for _,book in ipairs(shelf) do add(book) end end
    end
    local ok,settings=pcall(function() return host.settings and host.settings.get and host.settings:get('books',{}) end)
    if not ok then settings={} end
    if type(settings)=='table' then for id,book in pairs(settings) do
        if type(book)=='table' and not book.book_id and not book.bookId then
            add({book_id=id,title=book.title})
        else add(book) end
    end end
    return titles
end
function M.show(host)
    M.cancel(host)
    if not host.library_db or not host.library_db.open or not host.client then
        host:showInfo(_('Could not read offline changes.'));return false
    end
    local owner=context(host)
    if not current(host,owner) then host:showInfo(_('Sign in to view offline changes.'));return false end
    local finish=require('weread.ui.finish_offline')
    local membership=require('weread.ui.membership_offline')
    local f_ok,finished=pcall(finish.list,host)
    local m_ok,members=pcall(membership.list,host)
    if not f_ok or type(finished)~='table' or not m_ok or type(members)~='table' or not current(host,owner) then
        host:showInfo(_('Could not read offline changes.'));return false
    end
    local records={}
    for _,entry in ipairs(finished) do records[#records+1]={kind='finish',value=entry,module=finish} end
    for _,entry in ipairs(members) do records[#records+1]={kind='membership',value=entry,module=membership} end
    table.sort(records,function(a,b)
        if a.value.created_at~=b.value.created_at then return a.value.created_at<b.value.created_at end
        if a.value.book_id~=b.value.book_id then return a.value.book_id<b.value.book_id end
        return a.kind<b.kind
    end)
    if #records==0 then host:showInfo(_('No offline changes.'));return false end
    local titles=title_map(host)
    local items,menu={}
    for _index,record in ipairs(records) do
        local entry=record.value
        local title=type(entry.title)=='string' and entry.title~='' and entry.title or titles[entry.book_id]
        if type(title)~='string' or title=='' then title=T(_('Book ID: %1'),entry.book_id) end
        local action=record.kind=='finish' and (entry.desired and _('Mark finished') or _('Mark unfinished'))
            or (entry.desired and _('Add to shelf') or _('Remove from shelf'))
        local status=_(entry.phase=='queued' and 'Pending sync' or 'Needs review')
        items[#items+1]={text=title,mandatory=T(_('%1 · %2'),action,status),callback=function()
                if host._offline_changes_menu~=menu or not current(host,owner) then return end
                local ok,fresh,reason=pcall(record.module.get,host,entry.book_id)
                if not ok or reason then host:showInfo(_('Could not read offline changes.'));return end
                if not fresh or fresh.id~=entry.id or fresh.phase~=entry.phase
                    or fresh.before~=entry.before or fresh.desired~=entry.desired then
                    if M.show(host) then host:showInfo(_('Offline changes have changed. The list was refreshed.')) end
                    return
                end
                M.cancel(host)
                require('weread.ui.shelf_state').show(host,entry.book_id)
            end}
    end
    menu=host:showList(_('Offline changes'),items)
    if not menu then return false end
    host._offline_changes_menu=menu;menu._offline_owner=owner.owner
    local close=menu.onCloseWidget
    menu.onCloseWidget=function(widget,...)
        if host._offline_changes_menu==widget then host._offline_changes_menu=nil end
        if close then return close(widget,...) end
    end
    if owner.owner then Popup.show(owner.owner,menu,function() end) end
    return true
end
return M
