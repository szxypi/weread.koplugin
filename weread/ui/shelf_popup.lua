-- A shelf owns one popup; queued actions cannot outlive either widget.
local UI=require('ui/uimanager')
local M={}
function M.redraw(owner,callback)
    if owner._shelf_closed then return end
    if owner._shelf_popup then owner._shelf_redraw=callback else callback() end
end
local function flush(owner)
    local callback=owner._shelf_redraw;owner._shelf_redraw=nil
    if callback and not owner._shelf_closed then
        -- Let the user's choice run first. A replacement popup keeps waiting;
        -- navigation closes the old owner and invalidates this redraw.
        UI:nextTick(function() M.redraw(owner,callback) end)
    end
end
function M.current(owner,dialog)
    return owner and not owner._shelf_closed and owner._shelf_popup==dialog
end
function M.close(owner)
    if not owner then return end
    local dialog=owner._shelf_popup
    owner._shelf_popup=nil
    if dialog then UI:close(dialog) end
    flush(owner)
end
function M.show(owner,dialog,show)
    M.close(owner)
    if owner._shelf_closed then return false end
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if owner._shelf_popup==instance then owner._shelf_popup=nil;flush(owner) end
        if on_close then return on_close(instance,...) end
    end
    owner._shelf_popup=dialog
    if show then show(dialog) else UI:show(dialog) end
    return true
end
return M
