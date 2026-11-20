-- Device-only shelf organisation. This module never sends account requests.
local Model=require('weread.lib.local_shelf_groups')
local Identity=require('weread.lib.shelf_snapshot')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local T=require('weread.lib.plugin_util').T
local M={}
local KEY='shelf_local_groups_v1'

local function commit(host,owner,alive,on_change,base,original,value)
    if not alive() or host.shelf_local_state~=base or host.shelf_local_original~=original then return false end
    if not value then host:showInfo(_('Could not update local group. Check the name and limits.'));return false end
    local ok,saved=pcall(host.library_db.compareProfileState,host.library_db,KEY,original,value)
    if not ok or saved~=true or not alive() then
        if alive() then host:showInfo(_('Local groups changed or could not be saved. Reopen the bookshelf and try again.')) end
        return false
    end
    host.shelf_local_state,host.shelf_local_original=value,value
    Popup.close(owner);on_change();return true
end

function M.available(host,book)
    local db=host.library_db
    local id=Identity.persisted_id(book)
    if not id or not db or type(db.accountKey)~='function' or type(db.compareProfileState)~='function'
        or not host.shelf_local_owner or db:accountKey()~=host.shelf_local_owner or not Model.valid(host.shelf_local_state) then return false end
    for _,row in ipairs(host.shelf_regular or {}) do if Identity.persisted_id(row)==id then return true end end
    return false
end

function M.open(host,owner,is_current,on_change)
    local db=host.library_db
    local account=host.shelf_local_owner
    if not account or not Model.valid(host.shelf_local_state) or not db or type(db.compareProfileState)~='function' then return false end
    local function alive()
        return not owner._shelf_closed and is_current() and db:accountKey()==account and host.shelf_local_owner==account
    end
    local base,original=host.shelf_local_state,host.shelf_local_original
    local function save(action)
        if not alive() then return false end
        return commit(host,owner,alive,on_change,base,original,Model.change(base,action))
    end
    local function transition(widget,callback)
        UI:nextTick(function()
            if not alive() or not Popup.current(owner,widget) then return end
            Popup.close(owner)
            if alive() then callback() end
        end)
    end
    local show_list,show_group,show_books,show_input
    show_input=function(group)
        local dialog
        dialog=require('ui/widget/inputdialog'):new{
            title=group and _('Rename local group') or _('Create local group'),input=group and group.name or '',input_type='text',
            buttons={{{text=_('Cancel'),callback=function() transition(dialog,show_list) end},
                {text=_('Save'),is_enter_default=true,callback=function()
                    if not alive() or not Popup.current(owner,dialog) then return end
                    save{kind=group and 'rename' or 'create',id=group and group.id,name=dialog:getInputText()}
                end}}},
        }
        Popup.show(owner,dialog,function(widget) host:showInputDialog(widget) end)
    end
    show_books=function(group)
        local selected={};for _,id in ipairs(group.books) do selected[id]=true end
        local rows,menu={},nil
        rows[#rows+1]={text=_('Save local group books'),callback=function()
            if not alive() or not Popup.current(owner,menu) then return end
            local ordered,seen={},{}
            for _,id in ipairs(group.books) do
                if selected[id] and not seen[id] then ordered[#ordered+1]=id;seen[id]=true end
            end
            for _,book in ipairs(host.shelf_regular or {}) do
                local id=Identity.persisted_id(book)
                if id and selected[id] and not seen[id] then ordered[#ordered+1]=id;seen[id]=true end
            end
            save{kind='books',id=group.id,books=ordered}
        end}
        for _,book in ipairs(host.shelf_regular or {}) do
            local id=Identity.persisted_id(book)
            if id then
                local row={text=type(book.title)=='string' and book.title~='' and book.title or _('Untitled book'),
                    mandatory=selected[id] and '✓' or ''}
                row.callback=function()
                    if not alive() or not Popup.current(owner,menu) then return end
                    selected[id]=not selected[id] or nil;row.mandatory=selected[id] and '✓' or '';menu:updateItems()
                end
                rows[#rows+1]=row
            end
        end
        menu=require('ui/widget/menu'):new{title=T(_('Books in local group: %1'),group.name),item_table=rows,
            subtitle=_('Books missing from the current shelf stay in this local group.'),items_per_page=12}
        Popup.show(owner,menu)
    end
    show_group=function(group)
        local dialog
        dialog=require('ui/widget/buttondialog'):new{title=T(_('Local group: %1'),group.name),buttons={
            {{text=_('Choose books'),callback=function() transition(dialog,function() show_books(group) end) end}},
            {{text=_('Rename'),callback=function() transition(dialog,function() show_input(group) end) end}},
            {{text=_('Delete local group'),callback=function() transition(dialog,function()
                local confirm
                confirm=require('ui/widget/confirmbox'):new{
                    text=_('Delete this local group? Books and cloud groups are kept.'),ok_text=_('Delete'),cancel_text=_('Cancel'),
                    keep_dialog_open=true,ok_callback=function()
                        if alive() and Popup.current(owner,confirm) then save{kind='delete',id=group.id} end
                    end,cancel_callback=function() transition(confirm,show_list) end,
                }
                Popup.show(owner,confirm)
            end) end}},
            {{text=_('Cancel'),callback=function() transition(dialog,show_list) end}},
        }}
        Popup.show(owner,dialog)
    end
    show_list=function()
        if not alive() then return end
        local rows,menu={},nil
        rows[1]={text=_('Create local group'),callback=function() transition(menu,function() show_input(nil) end) end}
        for _,group in ipairs(host.shelf_local_state.groups) do
            rows[#rows+1]={text=group.name,mandatory=tostring(#group.books),callback=function()
                transition(menu,function() show_group(group) end)
            end}
        end
        menu=require('ui/widget/menu'):new{title=_('Local groups on this device'),item_table=rows,
            subtitle=_('Local groups do not sync to WeRead.'),items_per_page=12}
        Popup.show(owner,menu)
    end
    show_list();return true
end

-- Change memberships for a single visible shelf book in one local transaction.
function M.book(host,owner,book,is_current,on_change)
    if not M.available(host,book) then return false end
    local id=Identity.persisted_id(book);local account=host.shelf_local_owner
    local base,original=host.shelf_local_state,host.shelf_local_original
    local function alive()
        return not owner._shelf_closed and is_current() and Identity.persisted_id(book)==id
            and host.shelf_local_owner==account and M.available(host,book)
    end
    local selected={}
    for _,group in ipairs(base.groups) do
        for _,member in ipairs(group.books) do if member==id then selected[group.id]=true;break end end
    end
    local function ids()
        local result={};for _,group in ipairs(base.groups) do if selected[group.id] then result[#result+1]=group.id end end
        return result
    end
    local menu
    local rows={{text=_('Save local groups for this book'),callback=function()
        if alive() and Popup.current(owner,menu) then
            commit(host,owner,alive,on_change,base,original,Model.assign(base,id,ids()))
        end
    end}}
    rows[#rows+1]={text=_('Create local group for this book'),callback=function()
        UI:nextTick(function()
            if not alive() or not Popup.current(owner,menu) then return end
            Popup.close(owner)
            local dialog
            dialog=require('ui/widget/inputdialog'):new{title=_('Create local group for this book'),input='',input_type='text',
                buttons={{{text=_('Cancel'),callback=function() if Popup.current(owner,dialog) then Popup.close(owner) end end},
                    {text=_('Save'),is_enter_default=true,callback=function()
                        if not alive() or not Popup.current(owner,dialog) then return end
                        local created=Model.change(base,{kind='create',name=dialog:getInputText()})
                        local choices=ids()
                        if created then choices[#choices+1]=created.groups[#created.groups].id end
                        local value=created and Model.assign(created,id,choices)
                        commit(host,owner,alive,on_change,base,original,value)
                    end}}}}
            Popup.show(owner,dialog,function(widget) host:showInputDialog(widget) end)
        end)
    end}
    for _,group in ipairs(base.groups) do
        local row={text=group.name,mandatory=selected[group.id] and '✓' or ''}
        row.callback=function()
            if not alive() or not Popup.current(owner,menu) then return end
            selected[group.id]=not selected[group.id] or nil
            row.mandatory=selected[group.id] and '✓' or '';menu:updateItems()
        end
        rows[#rows+1]=row
    end
    menu=require('ui/widget/menu'):new{title=_('Local groups for this book'),item_table=rows,
        subtitle=_('Local groups do not sync to WeRead.'),items_per_page=12}
    Popup.show(owner,menu);return true
end
return M
