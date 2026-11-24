-- Prepare horizontal runs for a rounded cover's corner mask.  Building the
-- mask once avoids allocating tables and painting individual pixels on every
-- e-ink screen refresh.
local M = {}

function M.inside(x, y, width, height, radius)
    if x < 0 or y < 0 or x >= width or y >= height then return false end
    if radius <= 0 then return true end
    local cx, cy
    if x < radius and y < radius then
        cx, cy = radius, radius
    elseif x >= width - radius and y < radius then
        cx, cy = width - radius - 1, radius
    elseif x < radius and y >= height - radius then
        cx, cy = radius, height - radius - 1
    elseif x >= width - radius and y >= height - radius then
        cx, cy = width - radius - 1, height - radius - 1
    else
        return true
    end
    local dx, dy = x - cx, y - cy
    return dx * dx + dy * dy <= radius * radius
end

function M.spans(width, height, radius, offset, shadow)
    local spans = {}
    local function row(y, first, last)
        local run
        for x = first, last do
            local color
            if not M.inside(x, y, width, height, radius) then
                color = shadow and M.inside(x - offset, y - offset, width, height, radius)
                    and "shadow" or "white"
            end
            if color and run and run.color == color and run.x + run.width == x then
                run.width = run.width + 1
            elseif color then
                run = { x = x, y = y, width = 1, color = color }
                spans[#spans + 1] = run
            else
                run = nil
            end
        end
    end
    for dy = 0, radius - 1 do
        row(dy, 0, radius - 1)
        row(dy, width - radius, width - 1)
        row(height - 1 - dy, 0, radius - 1)
        row(height - 1 - dy, width - radius, width - 1)
    end
    return spans
end

return M
