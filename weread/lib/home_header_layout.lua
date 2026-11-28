-- Adapted from MiuRead; Copyright (C) 2026 MiuRead contributors. AGPL-3.0-only.
-- Pure header geometry: each visible item keeps its intrinsic/touch width,
-- while every intervening blank interval receives the same width.
local M={}
function M.arrange(available,items,min_gap)
    available=math.max(1,math.floor(tonumber(available) or 1))
    min_gap=math.max(0,math.floor(tonumber(min_gap) or 0))
    local remaining={}
    for _,entry in ipairs(items or {}) do
        remaining[#remaining+1]={key=entry.key,width=math.max(1,math.floor(tonumber(entry.width) or 1)),
            make=entry.make,callback=entry.callback,priority=entry.priority or 0}
    end
    local function needed()
        local n=#remaining
        local sum=math.max(0,n-1)*min_gap
        for _,entry in ipairs(remaining) do sum=sum+entry.width end
        return sum
    end
    -- On exceptionally narrow devices remove lowest-value status cells first.
    -- The title, Wi-Fi and menu are never removed by overflow fallback.
    while #remaining>1 and needed()>available do
        local worst,worst_priority
        for i,entry in ipairs(remaining) do
            if entry.priority>0 and (not worst_priority or entry.priority>worst_priority) then
                worst,worst_priority=i,entry.priority
            end
        end
        if not worst then break end
        table.remove(remaining,worst)
    end
    -- Extremely narrow viewports may not even hold title + Wi-Fi + tools.
    -- Keep the menu reachable; hide the decorative title before the network
    -- status, and preserve minimum tap widths whenever space permits.
    local function total_width()
        local total=0
        for _,entry in ipairs(remaining) do total=total+entry.width end
        return total
    end
    local function drop(key)
        for i,entry in ipairs(remaining) do
            if entry.key==key then table.remove(remaining,i);return true end
        end
        return false
    end
    while #remaining>1 and total_width()+math.max(0,#remaining-1)*min_gap>available do
        if not drop("title") and not drop("wifi") then table.remove(remaining,1) end
    end
    if #remaining==1 and remaining[1].width>available then
        remaining[1].width=available
    end
    local n=#remaining
    if n==0 then return remaining end
    local content=0
    for _,entry in ipairs(remaining) do content=content+entry.width end
    local extra=math.max(0,available-content)
    local gap=n>1 and math.floor(extra/(n-1)) or 0
    local remainder=n>1 and extra%(n-1) or 0
    local cursor=n==1 and math.max(0,math.floor((available-content)/2)) or 0
    for i,entry in ipairs(remaining) do
        entry.x=cursor
        cursor=cursor+entry.width
        if i<n then cursor=cursor+gap+(i<=remainder and 1 or 0) end
    end
    return remaining
end
return M
