-- Clip a long shelf's paint work while maintaining every row's input geometry.
local M = {}

function M.paint(group, bb, x, y, mirrored)
    local size = group:getSize()
    local align = group.align
    if mirrored and group.allow_mirroring then
        if align == 'left' then align = 'right'
        elseif align == 'right' then align = 'left' end
    end
    local screen_height = bb:getHeight()
    for index, widget in ipairs(group) do
        local position = group._offsets[index]
        local next_position = group._offsets[index + 1]
        local height = (next_position and next_position.y or size.h) - position.y
        local px = align == 'center' and x + math.floor((size.w - position.x) / 2)
            or align == 'right' and x + size.w - position.x or x
        local py = y + position.y
        if height > 0 and py < screen_height and py + height > 0 then
            widget:paintTo(bb, px, py)
        elseif widget._shelf_list_row then
            widget.dimen.x, widget.dimen.y = px, py
            if not widget.frame.dimen then widget.frame.dimen = widget.dimen:copy()
            else widget.frame.dimen.x, widget.frame.dimen.y = px, py end
        end
    end
end

return M
