-- Search terms are independent of the optional saved result batches.
local History=require('weread.lib.recent_searches')
local Popup=require('weread.ui.shelf_popup')
local Scope=require('weread.ui.page_scope')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.open(host,input)
    local owner=host.shelf_view
    if not owner or owner._shelf_closed or input and not Popup.current(owner,input) then return false end
    local scope=Scope.capture(host,owner)
    local snapshot,err,account,original=History.list(host)
    if not scope() then return false end
    if err then host:showInfo(_('Could not load recent searches.'));return false end
    if #snapshot.entries==0 then host:showInfo(_('No recent searches yet.'));return false end
    local menu,confirmation
    local function current() return scope() and host._discovery_menu==menu and Popup.current(owner,menu) end
    local function confirm(index)
        if not current() or confirmation then return end
        local dialog
        dialog=require('ui/widget/confirmbox'):new{
            text=_(index and 'Remove this search from recent searches?' or 'Clear all recent searches on this device?'),
            ok_text=_(index and 'Remove' or 'Clear'),cancel_text=_('Cancel'),keep_dialog_open=true,
            ok_callback=function()
                if confirmation~=dialog then return end
                confirmation=nil;UI:close(dialog)
                if not current() then return end
                local ok=index and History.remove(host,snapshot,account,original,index)
                    or not index and History.clear(host,snapshot,account,original)
                Popup.close(owner)
                if not ok then host:showInfo(_('Recent searches changed or could not be saved. Please try again.')) end
                M.open(host)
            end,
            cancel_callback=function() if confirmation==dialog then confirmation=nil;UI:close(dialog) end end,
        }
        confirmation=dialog
        local closed=dialog.onCloseWidget
        dialog.onCloseWidget=function(widget,...)
            if confirmation==widget then confirmation=nil end
            if closed then return closed(widget,...) end
        end
        UI:show(dialog)
    end
    local items={}
    for index,entry in ipairs(snapshot.entries) do
        items[#items+1]={text=entry.keyword,mandatory=_(entry.public and 'Public search' or 'WeRead search'),recent_index=index,
            callback=function()
                if not current() then return end
                host._discovery_menu=nil;Popup.close(owner)
                host:loadDiscoveryBatch('search',entry.keyword,0,false,false,entry.public and {public_search=true} or nil)
            end}
    end
    items[#items+1]={text=_('Clear recent searches'),clear_recent=true,callback=function() confirm(nil) end}
    menu=host:showList(_('Recent searches'),items,nil,{subtitle=_('Hold a search to remove it')})
    if not menu then return false end
    host._discovery_menu=menu
    local select=menu.onMenuSelect
    if select then
        function menu:onMenuSelect(item,...)
            if item and item.clear_recent then confirm(nil);return true end
            return select(self,item,...)
        end
    end
    function menu:onMenuHold(item)
        if type(item)=='table' and item.recent_index then confirm(item.recent_index) end
        return true
    end
    local closed=menu.onCloseWidget
    menu.onCloseWidget=function(widget,...)
        if confirmation then UI:close(confirmation);confirmation=nil end
        if host._discovery_menu==widget then host._discovery_menu=nil end
        if closed then return closed(widget,...) end
    end
    menu.close_callback=function() if host._discovery_menu==menu then host._discovery_menu=nil end end
    Popup.show(owner,menu,function() end)
    return true
end
return M
