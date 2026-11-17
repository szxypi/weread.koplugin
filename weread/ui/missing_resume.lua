-- Ask before replacing a missing resume chapter with another cached chapter.
local ConfirmBox=require('ui/widget/confirmbox')
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Scope=require('weread.ui.page_scope')
local _=require('weread.lib.plugin_util').tr
local M={}

function M.cancel(host)
    local state=host._missing_resume_confirmation
    host._missing_resume_confirmation=nil
    if not state then return end
    if state.owner and Popup.current(state.owner,state.dialog) then Popup.close(state.owner)
    else UI:close(state.dialog) end
end

function M.show(host,book_id,view,expected_uid)
    M.cancel(host)
    local owner=host.shelf_view
    if view and host._book_detail_view~=view then return false end
    local scope=Scope.capture(host,owner)
    local state={owner=owner};host._missing_resume_confirmation=state
    local dialog
    local function current()
        return host._missing_resume_confirmation==state and scope()
            and (not view or host._book_detail_view==view)
            and (not owner or Popup.current(owner,dialog))
    end
    dialog=ConfirmBox:new{
        text=_('Your last reading chapter is not cached. Opening another cached chapter may change your local reading position, even without turning a page. Continue?'),
        ok_text=_('Read cached copy'),cancel_text=_('Cancel'),
        ok_callback=function()
            if not current() then return end
            M.cancel(host)
            local latest=host.settings:get_book(book_id)
            if not latest then return end
            local available,reason,uid=host:openBookForReading(latest,true,{prefer_exact=true,check_only=true})
            if available or reason=='resume_not_cached' and uid==expected_uid then
                host:openBookForReading(latest)
            else
                host:showInfo(_('Reading position or cache changed. Please try again.'))
            end
        end,
        cancel_callback=function() if current() then M.cancel(host) end end,
    }
    state.dialog=dialog
    local closed=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if host._missing_resume_confirmation==state then host._missing_resume_confirmation=nil end
        if closed then return closed(widget,...) end
    end
    if owner then
        if not Popup.show(owner,dialog) then host._missing_resume_confirmation=nil;return false end
    else UI:show(dialog) end
    return true
end
return M
