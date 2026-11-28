-- Clip long lists to the paint buffer and optionally keep a window of rows.
local M = {}

local function child_x(align, x, width, position)
    local spare = width - position.x
    if align == 'center' then return x + math.floor(spare / 2) end
    if align == 'right' then return x + spare end
    return x
end

local function set_offscreen(widget, x, y)
    if widget.setOffscreenGeometry then widget:setOffscreenGeometry(x, y)
    else
        widget.dimen.x, widget.dimen.y = x, y
        if not widget.frame.dimen then widget.frame.dimen = widget.dimen:copy()
        else widget.frame.dimen.x, widget.frame.dimen.y = x, y end
    end
end

local function paint_window(offsets, height, y, screen_height)
    local low, high = 1, #offsets + 1
    while low < high do
        local middle = math.floor((low + high) / 2)
        local next_child = offsets[middle + 1]
        if y + (next_child and next_child.y or height) <= 0 then low = middle + 1
        else high = middle end
    end
    local last = low - 1
    while offsets[last + 1] and y + offsets[last + 1].y < screen_height do last = last + 1 end
    return low, last
end

function M.paint(group, bb, x, y, mirrored, windowed)
    local size = group:getSize()
    local align = group.align
    if mirrored and group.allow_mirroring then
        if align == 'left' then align = 'right'
        elseif align == 'right' then align = 'left' end
    end
    local screen_height = bb:getHeight()
    local offsets = group._offsets
    local first, last, painted_rows = 1, #offsets, nil
    if windowed then
        first, last = paint_window(offsets, size.h, y, screen_height)
        -- Only rows painted in the previous window can need eviction.
        for index = group._paint_first or 1, group._paint_last or 0 do
            if (index < first or index > last) and group[index] and group[index]._shelf_list_row then
                local position = offsets[index]
                set_offscreen(group[index], child_x(align, x, size.w, position), y + position.y)
            end
        end
        group._paint_first, group._paint_last = first, last
        painted_rows = {}
    end
    for index = first, last do
        local widget = group[index]
        local position = offsets[index]
        local next_position = offsets[index + 1]
        local height = (next_position and next_position.y or size.h) - position.y
        local px = child_x(align, x, size.w, position)
        local py = y + position.y
        if height > 0 and py < screen_height and py + height > 0 then
            widget:paintTo(bb, px, py)
            if painted_rows and widget._shelf_list_row then painted_rows[#painted_rows + 1] = widget end
        elseif not windowed and widget._shelf_list_row then
            set_offscreen(widget, px, py)
        end
    end
    return painted_rows
end

return M
