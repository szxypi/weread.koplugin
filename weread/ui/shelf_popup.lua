-- A shelf owns one popup; queued actions cannot outlive either widget.
local UI=require('ui/uimanager')
local M={}
function M.redraw(owner,callback)
    if owner._shelf_closed then return end
    if owner._shelf_popup then owner._shelf_redraw=callback else callback() end
end
-- A background result must not replace the page that owns an in-flight
-- automatic book-detail request. Its latest redraw can resume on cancellation.
function M.redrawForMetadata(host,owner,callback)
    if host.shelf_view~=owner or owner._shelf_closed then return end
    host._metadata_redraw_generation=(host._metadata_redraw_generation or 0)+1
    local context=host.book_metadata_context
    if context then
        context.pending_shelf_redraw={owner=owner,callback=callback,generation=host._metadata_redraw_generation}
        return
    end
    local generation=host._metadata_redraw_generation
    M.redraw(owner,function()
        if host.shelf_view~=owner or owner._shelf_closed or host._metadata_redraw_generation~=generation then return end
        -- A popup may have delayed this callback until after a new metadata
        -- request started. Check again when the redraw actually executes.
        if host.book_metadata_context then M.redrawForMetadata(host,owner,callback)
        else callback() end
    end)
end
function M.resumeMetadata(host,context)
    local pending=context.pending_shelf_redraw
    context.pending_shelf_redraw=nil
    if not pending then return end
    UI:nextTick(function()
        if host.shelf_view~=pending.owner or pending.owner._shelf_closed or host._book_detail_view
            or host._metadata_redraw_generation~=pending.generation then return end
        M.redrawForMetadata(host,pending.owner,pending.callback)
    end)
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
