-- Native, read-only personal notes; shared ownership for marks and thoughts. Parent owns persistence and popup lifetimes.
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
local function kind(row,owner)
    if owner.thoughts then return row.isPrivate==1 and _('Private thought') or _('Thought') end
    return row.type==1 and _('Highlight') or row.type==0 and _('Bookmark') or _('Cloud mark')
end
local function chapter(owner,row)
    if owner.thoughts and row.chapterName and row.chapterName~='' then return row.chapterName end
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
        local items={{text=_(owner.labels.refresh),callback=function() if current(host,owner) then refresh(host,owner) end end}}
        local filters=owner.thoughts and {{'All my thoughts',nil},{'Thoughts with quoted text',1},{'Other thoughts',0}}
            or {{'All cloud marks',nil},{'Highlights only',1},{'Bookmarks only',0}}
        for _i,filter in ipairs(filters) do
            local selected=filter[2]
            items[#items+1]={text=_(filter[1]),mandatory=owner.filter==selected and '✓' or '',callback=function()
                if current(host,owner) then owner.filter=selected;render(host,owner) end
            end}
        end
        if owner.value then
            local stamp=owner.value.fetched_at
            local date=stamp<=4102444800 and os.date('%Y-%m-%d %H:%M',stamp) or _('Time unavailable')
            items[#items+1]={text=_(owner.labels.saved),mandatory=date,select_enabled=false}
            local count=0
            for _i,row in ipairs(owner.thoughts and owner.value.reviews or owner.value.updated) do
                local has_quote=row.abstract~=nil and row.abstract~=''
                local row_type=owner.thoughts and (has_quote and 1 or 0) or row.type
                if owner.filter==nil or row_type==owner.filter then
                    count=count+1
                    local content=owner.thoughts and row.content or row.markText
                    if not content or content=='' then content=row.abstract end
                    if not content or content=='' then content=chapter(owner,row) end
                    items[#items+1]={text=preview(content or chapter(owner,row)),mandatory=kind(row,owner),callback=function()
                        if not current(host,owner) then return end
                        local parts={chapter(owner,row)}
                        if owner.thoughts then
                            if has_quote then parts[#parts+1]=_('Quoted text')..'\n'..row.abstract end
                            if row.content~='' then parts[#parts+1]=_('Thought')..'\n'..row.content
                            else parts[#parts+1]=_('No thought text was returned.') end
                        else
                            if row.markText and row.markText~='' then parts[#parts+1]=row.markText end
                            if row.abstract and row.abstract~='' and row.abstract~=row.markText then parts[#parts+1]=row.abstract end
                        end
                        if #parts==1 then parts[#parts+1]=_(owner.thoughts and 'No thought text was returned.' or 'No saved quote text.') end
                        Popup.show(owner.menu,require('ui/widget/textviewer'):new{title=kind(row,owner),text=table.concat(parts,'\n\n')})
                    end}
                end
            end
            if count==0 then items[#items+1]={text=_(owner.labels.empty),select_enabled=false} end
        else items[#items+1]={text=_(owner.labels.missing),select_enabled=false} end
        owner.menu:switchItemTable(nil,items)
    end)
end
refresh=function(host,owner)
    if not current(host,owner) or owner.context then return false end
    if not host:isNetworkOnline() then host:showOffline(_(owner.labels.title));return false end
    local access=owner.data.capture(host.settings)
    if not access then host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false end
    local context={};owner.context=context
    local function valid()
        return current(host,owner) and owner.context==context
            and (context.renewing and Recovery.current(host.settings,access,owner.data.capture) or owner.data.matches(host.settings,access))
    end
    local function failed()
        if current(host,owner) then host:showInfo(_(owner.labels.failed)) end
    end
    host:showBusy(_(owner.labels.loading),function() if owner.context==context then stop(host,owner) end end)
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
            local recovering=Recovery.start(host,context,access,{capture=owner.data.capture,
                is_current=function() return current(host,owner) and owner.context==context end,
                stale=function() if owner.context==context then stop(host,owner) end end,complete=function(success,renewed)
                    access=renewed
                    if success then launch() else stop(host,owner);failed() end
                end})
            if recovering then return end
        end
        stop(host,owner)
        local ok,value=pcall(owner.data.validate,host.client,result,owner.id)
        if not ok then failed();return end
        -- Persist before replacing the visible snapshot. A failed save leaves
        -- both the previous menu and its offline copy intact.
        local saved,success=pcall(owner.store.write,owner.store,value)
        if not current(host,owner) then return end
        if not saved or not success then host:showInfo(_(owner.labels.save_failed));return end
        owner.value=value;render(host,owner)
    end
    launch=function()
        if not valid() then stop(host,owner);return false end
        local ok,started=pcall(owner.worker.start,owner.worker,function()
            local success,value=pcall(owner.data.fetch,host.client,owner.id,access,{recover_auth=host.native_renewal~=nil and not context.recovery_attempted})
            return success and value or {native_expired=value==(owner.data.EXPIRED or 'my_marks/native_expired')}
        end,complete)
        if not ok or not started then stop(host,owner);failed();return false end
        return true
    end
    return launch()
end
function M.show(host,id,variant)
    if variant~=nil and variant~='thoughts' then return false end
    if not Data.id(id) or not host.library_db then return false end
    local scope=host.settings:get_auth_scope()
    if not host.library_db:accountKey() or not scope or not host.settings:auth_scope_matches(scope) then
        host:showInfo(_('Please scan the QR code to log in first.'));return false
    end
    M.cancel(host)
    local thoughts=variant=='thoughts'
    local owner={id=id,scope=scope,thoughts=thoughts,data=thoughts and require('weread.lib.my_cloud_thoughts') or Data,account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,
        session=host._reader_session_gen,document=host.ui and host.ui.document,parent=host._book_detail_view,
        store=Store:new(host.library_db,host.client,variant)}
    owner.labels=thoughts and {title='My cloud thoughts',refresh='Refresh my cloud thoughts',saved='Saved cloud thoughts',
        empty='No thoughts in this view.',missing='No saved thoughts. Refresh while online.',failed='Could not update my thoughts. Saved thoughts are kept.',
        loading='Loading my thoughts…\nTap or press a key to cancel.',save_failed='Could not save my thoughts. The previous saved copy is kept.'}
        or {title='My cloud highlights',refresh='Refresh my cloud marks',saved='Saved cloud marks',empty='No cloud marks in this view.',
            missing='No saved cloud marks. Refresh while online.',failed='Could not update my cloud marks. Saved marks are kept.',
            loading='Loading my cloud marks…\nTap or press a key to cancel.',save_failed='Could not save my cloud marks. The previous saved copy is kept.'}
    local ok,value=pcall(owner.store.read,owner.store,id);owner.value=ok and value or nil
    if owner.account~=host.library_db:accountKey() or not host.settings:auth_scope_matches(scope) then return false end
    local menu=host:showList(_(owner.labels.title),{{text=_(owner.labels.missing),select_enabled=false}})
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
