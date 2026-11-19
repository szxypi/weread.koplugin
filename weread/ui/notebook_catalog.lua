-- Account-scoped native entry point to saved highlights, thoughts and bookmarks.
local Data=require('weread.lib.notebook_catalog')
local Store=require('weread.lib.notebook_catalog_store')
local Recovery=require('weread.lib.native_read_recovery')
local Popup=require('weread.ui.shelf_popup')
local Marks=require('weread.lib.my_cloud_marks')
local Search=require('weread.lib.shelf_search')
local Query=require('weread.lib.search_query')
local Protocol=require('weread.lib.protocol')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function current(host,owner)
    return host._notebook_owner==owner and host._notebook_menu==owner.menu and not owner.menu._shelf_closed
        and owner.account==host.library_db:accountKey() and owner.account~=nil
        and owner.epoch==(host.discovery_epoch or 0) and owner.session==host._reader_session_gen
        and owner.document==(host.ui and host.ui.document) and host.settings:auth_scope_matches(owner.scope)
end
local function stop(host,owner)
    require('weread.ui.notebook_search').cancel(host,owner)
    local context=owner.context;owner.context=nil
    if not context then return end
    if owner.worker then owner.worker:cancel() end
    Recovery.cancel(host,context)
    if context.busy and host.busy_message==context.busy then host:closeBusy() end
end
local function close_child(host,owner)
    if owner.child and host._my_marks_owner==owner.child then host:cancelMyCloudMarks() end
    owner.child=nil
end
function M.cancel(host)
    local owner=host._notebook_owner;host._notebook_owner=nil
    local menu=host._notebook_menu;host._notebook_menu=nil
    if owner then stop(host,owner);close_child(host,owner) end
    if menu then menu._shelf_closed=true;Popup.close(menu);UI:close(menu) end
end
local render,refresh
local function search_dialog(host,owner)
    local dialog
    local function valid() return current(host,owner) and Popup.current(owner.menu,dialog) end
    local function apply(value)
        if not valid() then return end
        local query=Query.trim(value)
        if #query>1024 then host:showInfo(_('Search text is too long.'));return end
        owner.search=query~='' and query or nil;owner.needle=Search.prepare(owner.search)
        Popup.close(owner.menu);render(host,owner)
    end
    dialog=require('ui/widget/inputdialog'):new{title=_('Search notebooks'),input=owner.search or '',input_type='text',buttons={{
        {text=_('Clear'),callback=function() apply('') end},
        {text=_('Search'),is_enter_default=true,callback=function() apply(dialog:getInputText()) end},
    }}}
    Popup.show(owner.menu,dialog,function(widget) host:showInputDialog(widget) end)
end
local function ordered_books(owner)
    local entries={}
    for index,book in ipairs(owner.value.books) do
        if Search.matches(book,owner.needle) then
            local total
            if book.noteCount~=nil and book.reviewCount~=nil and book.bookmarkCount~=nil then
                total=book.noteCount+book.reviewCount+book.bookmarkCount
            end
            entries[#entries+1]={book=book,index=index,total=total}
        end
    end
    if owner.sort=='count' then
        table.sort(entries,function(a,b)
            if a.total==b.total then return a.index<b.index end
            if a.total==nil then return false end
            if b.total==nil then return true end
            return a.total>b.total
        end)
    end
    return entries
end
local function sort_dialog(host,owner)
    local dialog
    local function choice(label,sort)
        return {text=_(label)..(owner.sort==sort and ' ✓' or ''),callback=function()
            if not current(host,owner) or not Popup.current(owner.menu,dialog) then return end
            owner.sort=sort;Popup.close(owner.menu);render(host,owner)
        end}
    end
    dialog=require('ui/widget/buttondialog'):new{title=_('Sort notebooks'),buttons={
        {choice('Original order','original')},{choice('Most notes first','count')},
    }}
    Popup.show(owner.menu,dialog)
end
local function open_book(host,owner,book)
    if not current(host,owner) then return end
    if not Marks.display_id(book.bookId) then host:showInfo(_('This book type is not supported for cloud notes.'));return end
    local dialog
    local function button(label,method,count)
        return {text=_(label)..(count~=nil and ' ('..tostring(count)..')' or ''),callback=function()
            if not current(host,owner) or not Popup.current(owner.menu,dialog) then return end
            Popup.close(owner.menu)
            host[method](host,book.bookId)
            if current(host,owner) then owner.child=host._my_marks_owner end
        end}
    end
    dialog=require('ui/widget/buttondialog'):new{title=book.title,buttons={
        {button('My cloud highlights','showMyCloudMarks',book.noteCount)},
        {button('My cloud thoughts','showMyCloudThoughts',book.reviewCount)},
        {button('My cloud bookmarks','showMyCloudBookmarks',book.bookmarkCount)},
    }}
    Popup.show(owner.menu,dialog)
end
render=function(host,owner)
    if not current(host,owner) then return end
    Popup.redraw(owner.menu,function()
        if not current(host,owner) then return end
        owner.generation=(owner.generation or 0)+1
        local generation=owner.generation
        local items={{text=_('Refresh my notebooks'),callback=function() if current(host,owner) then refresh(host,owner) end end},
            {text=_('Search all saved notes'),callback=function()
                if current(host,owner) then require('weread.ui.notebook_search').prompt(host,owner,current) end
            end}}
        if owner.value then
            local search_text=owner.search and Protocol.utf8_substr(owner.search,16) or ''
            if owner.search and #search_text<#owner.search then search_text=search_text..'…' end
            items[#items+1]={text=_('Search notebooks'),mandatory=search_text,callback=function()
                if current(host,owner) then search_dialog(host,owner) end
            end}
            items[#items+1]={text=_('Sort notebooks'),mandatory=_(owner.sort=='count' and 'Most notes first' or 'Original order'),callback=function()
                if current(host,owner) then sort_dialog(host,owner) end
            end}
            local stamp=owner.value.fetched_at
            local date=stamp<=4102444800 and os.date('%Y-%m-%d %H:%M',stamp) or _('Time unavailable')
            items[#items+1]={text=_('Saved notebooks'),mandatory=date,select_enabled=false}
            local entries=ordered_books(owner)
            for _,entry in ipairs(entries) do
                local book=entry.book
                items[#items+1]={text=book.title,mandatory=book.author,notebook_id=book.bookId,callback=function()
                    if owner.generation==generation then open_book(host,owner,book) end
                end}
            end
            if #entries==0 then items[#items+1]={text=_(owner.needle and 'No matching notebooks.' or 'No notebooks yet.'),select_enabled=false} end
        else items[#items+1]={text=_('No saved notebooks. Refresh while online.'),select_enabled=false} end
        owner.menu:switchItemTable(nil,items)
    end)
end
refresh=function(host,owner)
    if not current(host,owner) or owner.context then return false end
    require('weread.ui.notebook_search').cancel(host,owner)
    if not host:isNetworkOnline() then host:showOffline(_('My notebooks'));return false end
    local access=Data.capture(host.settings)
    if not access then host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false end
    local context={};owner.context=context
    local function valid()
        return current(host,owner) and owner.context==context
            and (context.renewing and Recovery.current(host.settings,access,Data.capture) or Data.matches(host.settings,access))
    end
    local function failed() if current(host,owner) then host:showInfo(_('Could not update my notebooks. Saved notebooks are kept.')) end end
    host:showBusy(_('Loading my notebooks…\nTap or press a key to cancel.'),function() if owner.context==context then stop(host,owner) end end)
    context.busy=host.busy_message
    if not owner.worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=Store.MAX_PAYLOAD} end)
        if not ok then stop(host,owner);failed();return false end
        owner.worker=worker
    end
    local launch
    local function complete(result)
        if not valid() then if owner.context==context then stop(host,owner) end;return end
        if type(result)=='table' and result.native_expired then
            local recovering=Recovery.start(host,context,access,{capture=Data.capture,
                is_current=function() return current(host,owner) and owner.context==context end,
                stale=function() if owner.context==context then stop(host,owner) end end,complete=function(success,renewed)
                    access=renewed
                    if success then launch() else stop(host,owner);failed() end
                end})
            if recovering then return end
        end
        stop(host,owner)
        local ok,value=pcall(Data.validate,host.client,result)
        if not ok then failed();return end
        local saved,success=pcall(owner.store.write,owner.store,value)
        if not current(host,owner) then return end
        if not saved or not success then host:showInfo(_('Could not save my notebooks. The previous saved copy is kept.'));return end
        owner.value=value;render(host,owner)
    end
    launch=function()
        if not valid() then stop(host,owner);return false end
        local ok,started=pcall(owner.worker.start,owner.worker,function()
            local success,value=pcall(Data.fetch,host.client,access,{recover_auth=host.native_renewal~=nil and not context.recovery_attempted})
            return success and value or {native_expired=value==Data.EXPIRED}
        end,complete)
        if not ok or not started then stop(host,owner);failed();return false end
        return true
    end
    return launch()
end
function M.show(host,options)
    if not host.library_db then return false end
    local scope=host.settings:get_auth_scope()
    if not host.library_db:accountKey() or not scope or not host.settings:auth_scope_matches(scope) then
        host:showInfo(_('Please scan the QR code to log in first.'));return false
    end
    host:closeWeReadUI()
    if not host.settings:auth_scope_matches(scope) then return false end
    local account=host.library_db:accountKey()
    if not account then return false end
    local owner={scope=scope,account=account,epoch=host.discovery_epoch or 0,session=host._reader_session_gen,sort='original',
        document=host.ui and host.ui.document,store=Store:new(host.library_db,host.client,account)}
    local ok,value=pcall(owner.store.read,owner.store);owner.value=ok and value or nil
    if owner.account~=host.library_db:accountKey() or not host.settings:auth_scope_matches(scope) then return false end
    local menu=host:showList(_('My notebooks'),{{text=_('No saved notebooks. Refresh while online.'),select_enabled=false}})
    if not menu then return false end
    owner.menu=menu;host._notebook_owner=owner;host._notebook_menu=menu
    local on_close=menu.onCloseWidget
    menu.onCloseWidget=function(instance,...)
        instance._shelf_closed=true;Popup.close(instance);stop(host,owner);close_child(host,owner)
        if host._notebook_owner==owner then host._notebook_owner=nil;host._notebook_menu=nil end
        if on_close then return on_close(instance,...) end
    end
    render(host,owner)
    if options and options.search then
        require('weread.ui.notebook_search').prompt(host,owner,current)
    elseif not owner.value and host:isNetworkOnline() then refresh(host,owner) end
    return true
end
return M
