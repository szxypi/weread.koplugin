-- Native, read-only own marks. Parent owns persistence and popup lifetimes.
local Data=require('weread.lib.my_cloud_marks')
local Store=require('weread.lib.my_cloud_marks_store')
local Recovery=require('weread.lib.native_read_recovery')
local Popup=require('weread.ui.shelf_popup')
local Protocol=require('weread.lib.protocol')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function current(host,owner)
    return host._my_marks_owner==owner and host._my_marks_menu==owner.menu and not owner.menu._shelf_closed
        and owner.account==host.library_db:accountKey() and owner.account~=nil
        and owner.epoch==(host.discovery_epoch or 0) and owner.session==host._reader_session_gen
        and owner.document==(host.ui and host.ui.document) and owner.parent==host._book_detail_view
        and host.settings:auth_scope_matches(owner.scope)
end
local function stop(host,owner)
    local context=owner.context;owner.context=nil
    if not context then return end
    if owner.worker then owner.worker:cancel() end
    Recovery.cancel(host,context)
    if context.busy and host.busy_message==context.busy then host:closeBusy() end
end
function M.cancel(host)
    local owner=host._my_marks_owner;host._my_marks_owner=nil
    local menu=host._my_marks_menu;host._my_marks_menu=nil
    if owner then stop(host,owner) end
    if menu then menu._shelf_closed=true;Popup.close(menu);UI:close(menu) end
end
local function kind(row)
    return row.type==1 and _('Highlight') or row.type==0 and _('Bookmark') or _('Cloud mark')
end
local function chapter(owner,row)
    return owner.chapter_titles and owner.chapter_titles[row.chapterUid] or _('Chapter unavailable')
end
local function preview(value)
    return Protocol.utf8_substr(value:gsub('[%z%c]',' '),80)
end
local render,refresh
render=function(host,owner)
    if not current(host,owner) then return end
    Popup.redraw(owner.menu,function()
        if not current(host,owner) then return end
        owner.chapter_titles={}
        for _i,item in ipairs(owner.value and owner.value.chapters or {}) do owner.chapter_titles[item.chapterUid]=item.title end
        local items={{text=_('Refresh my cloud marks'),callback=function() if current(host,owner) then refresh(host,owner) end end}}
        local filters={{'All cloud marks',nil},{'Highlights only',1},{'Bookmarks only',0}}
        for _i,filter in ipairs(filters) do
            local selected=filter[2]
            items[#items+1]={text=_(filter[1]),mandatory=owner.filter==selected and '✓' or '',callback=function()
                if current(host,owner) then owner.filter=selected;render(host,owner) end
            end}
        end
        if owner.value then
            local stamp=owner.value.fetched_at
            local date=stamp<=4102444800 and os.date('%Y-%m-%d %H:%M',stamp) or _('Time unavailable')
            items[#items+1]={text=_('Saved cloud marks'),mandatory=date,select_enabled=false}
            local count=0
            for _i,row in ipairs(owner.value.updated) do
                if owner.filter==nil or row.type==owner.filter then
                    count=count+1
                    local content=row.markText~='' and row.markText or row.abstract
                    items[#items+1]={text=preview(content or chapter(owner,row)),mandatory=kind(row),callback=function()
                        if not current(host,owner) then return end
                        local parts={chapter(owner,row)}
                        if row.markText and row.markText~='' then parts[#parts+1]=row.markText end
                        if row.abstract and row.abstract~='' and row.abstract~=row.markText then parts[#parts+1]=row.abstract end
                        if #parts==1 then parts[#parts+1]=_('No saved quote text.') end
                        Popup.show(owner.menu,require('ui/widget/textviewer'):new{title=kind(row),text=table.concat(parts,'\n\n')})
                    end}
                end
            end
            if count==0 then items[#items+1]={text=_('No cloud marks in this view.'),select_enabled=false} end
        else items[#items+1]={text=_('No saved cloud marks. Refresh while online.'),select_enabled=false} end
        owner.menu:switchItemTable(nil,items)
    end)
end
refresh=function(host,owner)
    if not current(host,owner) or owner.context then return false end
    if not host:isNetworkOnline() then host:showOffline(_('My cloud highlights'));return false end
    local access=Data.capture(host.settings)
    if not access then host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false end
    local context={};owner.context=context
    local function valid()
        return current(host,owner) and owner.context==context
            and (context.renewing and Recovery.current(host.settings,access,Data.capture) or Data.matches(host.settings,access))
    end
    local function failed()
        if current(host,owner) then host:showInfo(_('Could not update my cloud marks. Saved marks are kept.')) end
    end
    host:showBusy(_('Loading my cloud marks…\nTap or press a key to cancel.'),function() if owner.context==context then stop(host,owner) end end)
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
        local ok,value=pcall(Data.validate,host.client,result,owner.id)
        if not ok then failed();return end
        -- Persist before replacing the visible snapshot. A failed save leaves
        -- both the previous menu and its offline copy intact.
        local saved,success=pcall(owner.store.write,owner.store,value)
        if not current(host,owner) then return end
        if not saved or not success then host:showInfo(_('Could not save my cloud marks. The previous saved copy is kept.'));return end
        owner.value=value;render(host,owner)
    end
    launch=function()
        if not valid() then stop(host,owner);return false end
        local ok,started=pcall(owner.worker.start,owner.worker,function()
            local success,value=pcall(Data.fetch,host.client,owner.id,access,{recover_auth=host.native_renewal~=nil and not context.recovery_attempted})
            return success and value or {native_expired=value=='my_marks/native_expired'}
        end,complete)
        if not ok or not started then stop(host,owner);failed();return false end
        return true
    end
    return launch()
end
function M.show(host,id)
    if not Data.id(id) or not host.library_db then return false end
    local scope=host.settings:get_auth_scope()
    if not host.library_db:accountKey() or not scope or not host.settings:auth_scope_matches(scope) then
        host:showInfo(_('Please scan the QR code to log in first.'));return false
    end
    M.cancel(host)
    local owner={id=id,scope=scope,account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,
        session=host._reader_session_gen,document=host.ui and host.ui.document,parent=host._book_detail_view,
        store=Store:new(host.library_db,host.client)}
    local ok,value=pcall(owner.store.read,owner.store,id);owner.value=ok and value or nil
    if owner.account~=host.library_db:accountKey() or not host.settings:auth_scope_matches(scope) then return false end
    local menu=host:showList(_('My cloud highlights'),{{text=_('No saved cloud marks. Refresh while online.'),select_enabled=false}})
    if not menu then return false end
    owner.menu=menu;host._my_marks_owner=owner;host._my_marks_menu=menu
    local on_close=menu.onCloseWidget
    menu.onCloseWidget=function(instance,...)
        instance._shelf_closed=true;Popup.close(instance);stop(host,owner)
        if host._my_marks_owner==owner then host._my_marks_owner=nil;host._my_marks_menu=nil end
        if on_close then return on_close(instance,...) end
    end
    render(host,owner)
    -- Cached snapshots open immediately, including offline. Refresh is explicit.
    if not owner.value and host:isNetworkOnline() then refresh(host,owner) end
    return true
end
return M
