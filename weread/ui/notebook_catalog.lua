-- Account-scoped native entry point to saved highlights, thoughts and bookmarks.
local Data=require('weread.lib.notebook_catalog')
local Store=require('weread.lib.notebook_catalog_store')
local Recovery=require('weread.lib.native_read_recovery')
local Popup=require('weread.ui.shelf_popup')
local Marks=require('weread.lib.my_cloud_marks')
local Search=require('weread.lib.shelf_search')
local Query=require('weread.lib.search_query')
local Protocol=require('weread.lib.protocol')
local NetworkLink=require('weread.lib.network_link')
local UI=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function current(host,owner)
    return host._notebook_owner==owner and host._notebook_menu==owner.menu and not owner.menu._shelf_closed
        and owner.account==host.library_db:accountKey() and owner.account~=nil
        and owner.epoch==(host.discovery_epoch or 0) and owner.session==host._reader_session_gen
        and owner.document==(host.ui and host.ui.document) and host.settings:auth_scope_matches(owner.scope)
end
local function stop(host,owner)
    local notes=package.loaded['weread.ui.my_cloud_marks']
    if notes then notes.cancel_saved(host,owner.menu) end
    require('weread.ui.notebook_bulk').cancel(host,owner)
    require('weread.ui.notebook_image_bulk').cancel(host,owner)
    require('weread.ui.thought_editor').cancel(host,owner)
    require('weread.ui.notebook_search').cancel(host,owner)
    local context=owner.context;owner.context=nil
    if not context then return end
    local worker=context.worker or owner.worker
    if worker then worker:cancel() end
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
local function search_dialog(host,menu,view,is_current,update)
    local dialog
    local function valid() return is_current() and Popup.current(menu,dialog) end
    local function apply(value)
        if not valid() then return end
        local query=Query.trim(value)
        if #query>1024 then host:showInfo(_('Search text is too long.'));return end
        view.search=query~='' and query or nil;view.needle=Search.prepare(view.search);view.terms=Search.terms(view.needle)
        Popup.close(menu);update()
    end
    dialog=require('ui/widget/inputdialog'):new{title=_('Search notebooks'),input=view.search or '',input_type='text',buttons={{
        {text=_('Clear'),callback=function() apply('') end},
        {text=_('Search'),is_enter_default=true,callback=function() apply(dialog:getInputText()) end},
    }}}
    Popup.show(menu,dialog,function(widget) host:showInputDialog(widget) end)
end
local function sort_by_count(books)
    local order,totals={},{}
    for index,book in ipairs(books) do
        order[index]=index
        if book.noteCount~=nil and book.reviewCount~=nil and book.bookmarkCount~=nil then
            totals[index]=book.noteCount+book.reviewCount+book.bookmarkCount
        end
    end
    table.sort(order,function(a,b)
        local left,right=totals[a],totals[b]
        if left==right then return a<b end
        if left==nil then return false end
        return right==nil or left>right
    end)
    for index,original in ipairs(order) do order[index]=books[original] end
    return order
end
local function ordered_books(owner)
    local cache=owner.book_order
    if not cache or cache.snapshot~=owner.value then
        cache={snapshot=owner.value,normalize=Search.cached_fold()}
        owner.book_order=cache
    end
    if not cache.original or cache.needle~=owner.needle then
        local books=owner.value.books
        if owner.needle then
            books={}
            for _,book in ipairs(owner.value.books) do
                if Search.matches(book,owner.needle,owner.terms,cache.normalize) then books[#books+1]=book end
            end
        end
        cache.needle,cache.original,cache.by_count=owner.needle,books,nil
    end
    if owner.sort=='count' then
        if not cache.by_count then cache.by_count=sort_by_count(cache.original) end
        return cache.by_count
    end
    return cache.original
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
local function open_book(host,owner,book,saved_menu)
    local parent=saved_menu or owner.menu
    local function valid()
        return current(host,owner) and (not saved_menu or
            not saved_menu._shelf_closed and Popup.current(owner.menu,saved_menu))
    end
    if not valid() then return end
    if not Marks.display_id(book.bookId) then host:showInfo(_('This book type is not supported for cloud notes.'));return end
    local dialog
    local function button(label,method,count,variant)
        return {text=_(label)..(count~=nil and ' ('..tostring(count)..')' or ''),callback=function()
            if not valid() or not Popup.current(parent,dialog) then return end
            Popup.close(parent)
            if saved_menu then
                require('weread.ui.my_cloud_marks').open_saved_book(host,book.bookId,variant,saved_menu,
                    function() return valid() and not saved_menu._shelf_popup end,
                    function(opened)
                        if opened then owner.child=host._my_marks_owner
                        else host:showInfo(_('These saved notes are unavailable.')) end
                    end)
                return
            end
            host[method](host,book.bookId,{
                source=parent,
                current=function() return valid() and not parent._shelf_popup end,
                on_open=function(child) owner.child=child end,
            })
        end}
    end
    local buttons={}
    if not saved_menu or book.marks then
        buttons[#buttons+1]={button('My cloud highlights','showMyCloudMarks',book.noteCount)}
    end
    if not saved_menu or book.thoughts then
        buttons[#buttons+1]={button('My cloud thoughts','showMyCloudThoughts',book.reviewCount,'thoughts')}
    end
    if not saved_menu or book.marks then
        buttons[#buttons+1]={button('My cloud bookmarks','showMyCloudBookmarks',book.bookmarkCount,'bookmarks')}
    end
    dialog=require('ui/widget/buttondialog'):new{title=book.title,buttons=buttons}
    Popup.show(parent,dialog)
end

local function show_saved_books(host,owner,books)
    local menu,visible
    local view={value={books=books},sort='original'}
    local function valid() return menu and current(host,owner) and Popup.current(owner.menu,menu) and not menu._shelf_closed end
    local function items()
        visible=ordered_books(view)
        local rows={}
        for index,book in ipairs(visible) do
            rows[index]={text=book.title,mandatory=book.author,notebook_id=book.bookId,notebook_index=index}
        end
        if #rows==0 then
            rows[1]={text=_(view.needle and 'No matching notebooks.' or 'No books with saved notes.'),select_enabled=false}
        end
        return rows
    end
    for _i,book in ipairs(books) do
        if book.title=='' then book.title=T(_('Book %1'),book.bookId) end
    end
    menu=host:showList(_('Books with saved notes'),items(),nil,{
        thought_text=true,left_icon='appbar.search',on_choice=function(item)
            local index=item.notebook_index
            if valid() and index and menu.item_table[index]==item then
                require('weread.ui.my_cloud_marks').cancel_saved(host,menu)
                open_book(host,owner,visible[index],menu)
            end
        end,
    })
    if not menu then return end
    menu.onLeftButtonTap=function()
        if valid() then
            require('weread.ui.my_cloud_marks').cancel_saved(host,menu)
            search_dialog(host,menu,view,valid,function() menu:switchItemTable(nil,items()) end)
        end
        return true
    end
    local on_close=menu.onCloseWidget
    menu.onCloseWidget=function(widget,...)
        require('weread.ui.my_cloud_marks').cancel_saved(host,widget)
        widget._shelf_closed=true;Popup.close(widget);close_child(host,owner)
        if on_close then return on_close(widget,...) end
    end
    Popup.show(owner.menu,menu,function() end)
end

local function browse_saved(host,owner)
    if not current(host,owner) or owner.context or owner.menu._shelf_popup then return end
    local function failed() host:showInfo(_('Could not list books with saved notes.')) end
    local ok,worker=pcall(function()
        return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=8*1024*1024}
    end)
    if not ok or not worker then failed();return end
    local context={worker=worker};owner.context=context
    host:showBusy(_('Loading saved notebooks…\nTap or press a key to cancel.'),function()
        if owner.context==context then stop(host,owner) end
    end)
    context.busy=host.busy_message
    local catalog=owner.value
    local started,active=pcall(worker.start,worker,function()
        local ids=require('weread.lib.my_cloud_marks_store').with_read_snapshot(host.library_db,host.client,function(marks,thoughts)
            local marked,reviewed=marks:list_ids(),thoughts:list_ids()
            if marked and reviewed then return {marked,reviewed} end
        end)
        if not ids then return nil end
        local lookup=host.settings.book_lookup and host.settings:book_lookup()
        return Data.saved_books(catalog and catalog.books or {},ids[1],ids[2],function(id)
            local book=lookup and lookup(id)
            if type(book)=='table' and book.book_id==id
                and (not book._library_account_key or book._library_account_key==owner.account) then
                return book
            end
        end)
    end,function(books)
        if owner.context~=context then return end
        stop(host,owner)
        if not current(host,owner) or owner.value~=catalog or owner.menu._shelf_popup then return end
        if type(books)=='table' then show_saved_books(host,owner,books) else failed() end
    end)
    if not started or not active then stop(host,owner);failed() end
end

render=function(host,owner)
    if not current(host,owner) then return end
    Popup.redraw(owner.menu,function()
        if not current(host,owner) then return end
        local items={{text=_('Refresh my notebooks'),callback=function() if current(host,owner) then refresh(host,owner) end end},
            {text=_('Browse saved notes by book'),callback=function() browse_saved(host,owner) end},
            {text=_('Search all saved notes'),callback=function()
                if current(host,owner) then require('weread.ui.notebook_search').prompt(host,owner,current) end
            end},
            {text=_('Local thought drafts'),callback=function()
                if current(host,owner) then stop(host,owner);require('weread.ui.thought_editor').drafts(host,owner,current,render) end
            end}}
        local books,book_offset
        if owner.value then
            items[#items+1]={text=_('Save all notebook notes for offline use'),callback=function()
                if current(host,owner) then
                    require('weread.ui.notebook_search').cancel(host,owner)
                    require('weread.ui.notebook_bulk').start(host,owner,current)
                end
            end}
            items[#items+1]={text=_('Save only missing notebook notes'),callback=function()
                if current(host,owner) then
                    require('weread.ui.notebook_search').cancel(host,owner)
                    require('weread.ui.notebook_bulk').start(host,owner,current,true)
                end
            end}
            items[#items+1]={text=_('Save images from saved thoughts'),callback=function()
                if current(host,owner) then
                    require('weread.ui.notebook_search').cancel(host,owner)
                    require('weread.ui.notebook_image_bulk').start(host,owner,current)
                end
            end}
            items[#items+1]={text=_('Clear saved thought and review images'),callback=function()
                if current(host,owner) then
                    require('weread.ui.notebook_search').cancel(host,owner)
                    require('weread.ui.notebook_image_bulk').clear(host,owner,current)
                end
            end}
            local search_text=owner.search and Protocol.utf8_substr(owner.search,16) or ''
            if owner.search and #search_text<#owner.search then search_text=search_text..'…' end
            items[#items+1]={text=_('Search notebooks'),mandatory=search_text,callback=function()
                if current(host,owner) then
                    search_dialog(host,owner.menu,owner,function() return current(host,owner) end,
                        function() render(host,owner) end)
                end
            end}
            items[#items+1]={text=_('Sort notebooks'),mandatory=_(owner.sort=='count' and 'Most notes first' or 'Original order'),callback=function()
                if current(host,owner) then sort_dialog(host,owner) end
            end}
            local stamp=owner.value.fetched_at
            local date=stamp<=4102444800 and os.date('%Y-%m-%d %H:%M',stamp) or _('Time unavailable')
            items[#items+1]={text=_('Saved notebooks'),mandatory=date,select_enabled=false}
            books=ordered_books(owner)
            book_offset=#items
            for index,book in ipairs(books) do
                local item_index=book_offset+index
                items[item_index]={text=book.title,mandatory=book.author,notebook_id=book.bookId,notebook_index=item_index}
            end
            if #books==0 then items[#items+1]={text=_(owner.needle and 'No matching notebooks.' or 'No notebooks yet.'),select_enabled=false} end
        else items[#items+1]={text=_('No saved notebooks. Refresh while online.'),select_enabled=false} end
        owner.visible_books,owner.book_offset=books,book_offset
        owner.menu:switchItemTable(nil,items)
    end)
end
refresh=function(host,owner,automatic)
    if not current(host,owner) or owner.context then return false end
    if not automatic then
        require('weread.ui.notebook_bulk').cancel(host,owner)
        require('weread.ui.notebook_search').cancel(host,owner)
    end
    if not NetworkLink.available(host) then
        if not automatic then host:showOffline(_('My notebooks')) end
        return false
    end
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
    local menu=host:showList(_('My notebooks'),{{text=_('No saved notebooks. Refresh while online.'),select_enabled=false}},nil,{
        thought_text=true,on_choice=function(item)
            local index=item.notebook_index
            if index then
                -- An old widget can still hold a row from before a redraw.
                if owner.menu.item_table[index]==item then
                    open_book(host,owner,owner.visible_books[index-owner.book_offset])
                end
            elseif item.callback then
                item.callback()
            end
        end,
    })
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
    elseif not owner.value then refresh(host,owner,true) end
    return true
end
return M
