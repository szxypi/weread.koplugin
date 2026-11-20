-- In-memory native locations. Pixel offsets are reusable only with the same
-- layout; after reflow the verified text pointer remains the fallback.
local Position=require('weread.lib.reader_position')
local M={}
local function finite(value)
    return type(value)=='number' and value==value and value>=0 and value<1e15
end
local function viewport(ui)
    local snapshot=Position.snapshot(ui.document,ui.view and ui.view.view_mode,ui.dimen and ui.dimen.h)
    if not snapshot then return end
    snapshot.viewport_width=ui.dimen and ui.dimen.w
    local footer=ui.view and ui.view.footer
    snapshot.footer_height=footer and footer.getHeight and footer:getHeight() or 0
    snapshot.footer_visible=ui.view and ui.view.footer_visible==true
    snapshot.footer_reclaims=footer and footer.settings and footer.settings.reclaim_height==true or false
    return snapshot
end
function M.capture(ui,marker)
    return {xpointer=ui.rolling.xpointer,marker_xpointer=marker,viewport=viewport(ui)}
end
local function pixel_match(saved,current)
    if not saved or not current or saved.view_mode~='scroll' or current.view_mode~='scroll'
        or not finite(saved.pos) or not finite(saved.height) or saved.height<=0
        or not finite(saved.viewport_height) or saved.viewport_height<=0
        or not finite(saved.viewport_width) or saved.viewport_width<=0
        or saved.rendering_hash==nil or current.rendering_hash==nil then return false end
    for _i,key in ipairs({'rendering_hash','pages','height','viewport_width','viewport_height',
        'footer_height','footer_visible','footer_reclaims'}) do
        if saved[key]~=current[key] then return false end
    end
    return true
end
function M.restore(ui,point)
    if type(point)~='table' or type(point.xpointer)~='string' or #point.xpointer==0 or #point.xpointer>8192
        or not ui.document:isXPointerInDocument(point.xpointer) then return false end
    local exact=type(ui.rolling._gotoPos)=='function' and pixel_match(point.viewport,viewport(ui))
    -- The optional native marker computes screen coordinates before scrolling.
    -- Omit it on pixel restores so it cannot appear at a pre-correction offset.
    local marker=not exact and point.marker_xpointer or nil
    local ok=pcall(ui.rolling.onGotoXPointer,ui.rolling,point.xpointer,marker)
    if not ok or ui.rolling.xpointer~=point.xpointer then return false end
    if exact and pixel_match(point.viewport,viewport(ui)) then
        local moved=pcall(ui.rolling._gotoPos,ui.rolling,point.viewport.pos)
        if moved and ui.document:getCurrentPos()==point.viewport.pos then
            ui.rolling.xpointer=point.xpointer
            return true,'pixel'
        end
        -- A changed native clamp or viewport must not retain a partial jump.
        local restored=pcall(ui.rolling.onGotoXPointer,ui.rolling,point.xpointer,point.marker_xpointer)
        if not restored then return false end
    end
    return ui.rolling.xpointer==point.xpointer,'anchor'
end
return M
