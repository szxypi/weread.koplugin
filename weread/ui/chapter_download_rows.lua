-- Update the fixed-height native Menu rows used by the chapter download picker.
local UIManager = require("ui/uimanager")

local M = {}

local function update_row(change)
    local widget = change.widget
    local color = widget._underline_container.color
    widget:clear()
    widget.text = change.text
    widget.mandatory = change.mandatory
    widget:init()
    local size = widget[1]:getSize()
    if size.w ~= change.region.w or size.h ~= change.region.h then return false end
    -- The row remains in the same focus layout and keeps its underline.
    widget._underline_container.color = color
    return true
end

function M.update(menu)
    if menu._weread_closed or menu.items_max_lines or not menu.is_borderless or menu.show_parent ~= menu
        or not menu.item_group or type(menu.item_table) ~= "table" or not UIManager.getTopmostVisibleWidget
        or UIManager:getTopmostVisibleWidget() ~= menu then return false end
    local screen = require("device").screen
    local width, height = screen:getWidth(), screen:getHeight()
    if menu.screen_w ~= width or menu.screen_h ~= height then return false end

    local changes = {}
    for _, widget in ipairs(menu.item_group) do
        local entry = widget.entry
        if entry and (entry.download or entry.selection_options or entry.chapter_index) then
            local text, mandatory = entry.text, entry.mandatory
            if text ~= widget.text or mandatory ~= widget.mandatory then
                local region = widget[1] and widget[1].dimen
                if menu.item_table[widget.idx] ~= entry or not region or not widget._underline_container
                    or not widget.clear or not widget.init or region.w <= 0 or region.h <= 0
                    or region.x < 0 or region.y < 0 or region.x + region.w > width
                    or region.y + region.h > height then return false end
                changes[#changes + 1] = {
                    widget = widget, text = text, mandatory = mandatory, region = region:copy(),
                }
            end
        end
    end
    for _, change in ipairs(changes) do
        local ok, stable = pcall(update_row, change)
        if not ok or not stable then return false end
    end
    -- KOReader composites the menu in stack order. Submit one refresh to
    -- avoid driving the display twice for a selection.
    local dirty
    for _, change in ipairs(changes) do
        dirty = dirty and dirty:combine(change.region) or change.region
    end
    if dirty then UIManager:setDirty(menu, "ui", dirty) end
    return true
end

return M
