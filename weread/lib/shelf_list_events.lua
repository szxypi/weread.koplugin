-- Route point gestures to their shelf row after the list has been painted.
-- Other events retain KOReader's normal child-first propagation.
local M = {}
local gestures = { tap=true, hold=true, hold_release=true }
-- Shelf rows do not handle the scroller's movement gestures. Return them to
-- the parent without walking every row, so the scroller can handle them.
local scrolling = { touch=true, swipe=true, hold_pan=true, pan=true, pan_release=true }

local function finite(value)
    return type(value)=='number' and value==value and value>-math.huge and value<math.huge
end

function M.dispatch(rows, ready, event)
    if not ready or type(rows)~='table' or type(event)~='table' or event.handler~='onGesture'
        or type(event.args)~='table' or type(event.args[1])~='table' then return false end
    local gesture=event.args[1]
    if scrolling[gesture.ges] then return true,false end
    local pos=gesture.pos
    if not gestures[gesture.ges] or type(pos)~='table' or not finite(pos.x) or not finite(pos.y)
        or pos.w~=0 or pos.h~=0 then return false end
    local low,high,selected=1,#rows,nil
    while low<=high do
        local middle=math.floor((low+high)/2)
        local row=rows[middle]
        local dimen=row and row.dimen
        if not dimen or not finite(dimen.y) then return false end
        if dimen.y<=pos.y then selected=row;low=middle+1 else high=middle-1 end
    end
    if selected and selected.dimen:contains(pos) then return true,selected:handleEvent(event) end
    return true,false
end

function M.dispatchPainted(rows, event)
    if not rows or event.handler ~= 'onGesture' then return false end
    local routed, consumed = M.dispatch(rows, true, event)
    if routed then return routed, consumed end
    for _, row in ipairs(rows) do
        if row:handleEvent(event) then return true, true end
    end
    return true, false
end

return M
