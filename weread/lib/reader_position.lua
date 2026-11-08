-- Local KOReader geometry only. This does not interpret WeRead source offsets.
local _ = require("weread.lib.i18n").tr
local Position = {}

local function finite(value)
    value = tonumber(value)
    return value and value == value and math.abs(value) < math.huge and value or nil
end

local function read(document, method)
    if type(document[method]) ~= "function" then return nil end
    local ok, value = pcall(document[method], document)
    return ok and finite(value) or nil
end

local function ratio(value, total)
    value, total = finite(value), finite(total)
    if not value or value < 0 or not total or total <= 0 then return nil end
    return math.max(0, math.min(1, value / total))
end

function Position.fraction(document, footer, view_mode)
    if not document then return nil end
    local function page_fraction()
        return ratio(read(document, "getCurrentPage") or read(document, "getPageNumber"), read(document, "getPageCount"))
    end
    local function scroll_fraction()
        return ratio(read(document, "getCurrentPos") or document.current_pos,
            document.info and document.info.doc_height or document.doc_height)
    end
    local primary, secondary = page_fraction, scroll_fraction
    if view_mode == "scroll" then primary, secondary = secondary, primary end
    local value = primary()
    if value ~= nil then return value end
    value = secondary()
    if value ~= nil then return value end
    -- Footer updates may run after PageUpdate/PosUpdate listeners. It is only
    -- a compatibility fallback when the live document exposes no usable value.
    local cached = finite(footer and footer.percent_finished)
    if cached then return math.max(0, math.min(1, cached > 1 and cached / 100 or cached)) end
end

-- Small native viewport identity. A layout revision is distinct from moving
-- the viewport, so a selected target can survive repagination without treating
-- a later trip back to the same page as the original visit.
function Position.snapshot(document, view_mode, viewport_height)
    if not document then return nil end
    local page, pos = read(document, "getCurrentPage"), read(document, "getCurrentPos")
    if not page and not pos then return nil end
    local function bounded(method)
        if type(document[method]) ~= "function" then return nil end
        local ok, value = pcall(document[method], document, true)
        if not ok then return nil end
        if type(value) == "string" and #value <= 4096 then return value end
        if finite(value) then return value end
    end
    return { page = page, pos = pos, view_mode = view_mode or "page",
        xpointer = bounded("getXPointer"), rendering_hash = bounded("getDocumentRenderingHash"),
        pages = read(document, "getPageCount"), height = finite(document.info and document.info.doc_height),
        viewport_height = finite(viewport_height) }
end

function Position.same_view(left, right)
    return left and right and left.page == right.page and left.pos == right.pos
        and left.view_mode == right.view_mode and left.xpointer == right.xpointer
end

function Position.layout_changed(left, right)
    return left and right and (left.view_mode ~= right.view_mode
        or (left.rendering_hash ~= nil and right.rendering_hash ~= nil and left.rendering_hash ~= right.rendering_hash)
        or (left.pages ~= nil and right.pages ~= nil and left.pages ~= right.pages)
        or (left.height ~= nil and right.height ~= nil and left.height ~= right.height))
end

function Position.contains_anchor(document, frame, xpointer)
    if not document or not frame or type(xpointer) ~= "string" or xpointer == "" then return false end
    local ok, visible = pcall(function()
        if frame.view_mode == "scroll" then
            local at = finite(document:getPosFromXPointer(xpointer))
            if not at or not frame.pos then return false end
            return at >= frame.pos - 1 and at < frame.pos + math.max(1, frame.viewport_height or 1)
        end
        return document:isXPointerInCurrentPage(xpointer) == true
    end)
    return ok and visible == true
end

function Position.goto_fraction(ui, value)
    local fraction = finite(value)
    if not fraction or not ui then return false, _("Could not navigate to the reading position.") end
    local percent = math.max(0, math.min(1, fraction)) * 100
    local ok, result = pcall(function()
        if ui.rolling and type(ui.rolling.onGotoPercent) == "function" then
            return ui.rolling:onGotoPercent(percent)
        elseif type(ui.handleEvent) == "function" then
            return ui:handleEvent(require("ui/event"):new("GotoPercent", percent)) == true
        end
        return false
    end)
    if not ok then return false, result end
    if result == false then return false, _("Could not navigate to the reading position.") end
    return true
end

function Position.goto_xpointer(ui, xpointer)
    if not ui or type(xpointer) ~= 'string' or xpointer == '' or #xpointer > 4096 then return false end
    local ok, handled = pcall(function()
        if ui.rolling and type(ui.rolling.onGotoXPointer) == 'function' then
            return ui.rolling:onGotoXPointer(xpointer) ~= false
        end
        if type(ui.handleEvent) == 'function' then
            return ui:handleEvent(require('ui/event'):new('GotoXPointer',xpointer)) == true
        end
        return false
    end)
    return ok and handled == true
end

return Position
