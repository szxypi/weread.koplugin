package.path = "./?.lua;./?/init.lua;" .. package.path
local Mask = require("weread.lib.cover_mask")

-- Compare every output pixel to the original rounded-corner calculation,
-- including the grey shadow visible behind the lower/right corners.
local function inside(x, y, w, h, r)
    if x < 0 or y < 0 or x >= w or y >= h then return false end
    if r <= 0 then return true end
    local cx, cy
    if x < r and y < r then cx, cy = r, r
    elseif x >= w - r and y < r then cx, cy = w - r - 1, r
    elseif x < r and y >= h - r then cx, cy = r, h - r - 1
    elseif x >= w - r and y >= h - r then cx, cy = w - r - 1, h - r - 1
    else return true end
    return (x - cx)^2 + (y - cy)^2 <= r^2
end

for _, size in ipairs({ {1, 1}, {20, 30}, {100, 150}, {241, 301} }) do
    local w, h = size[1], size[2]
    for r = 0, math.min(math.floor(math.min(w, h) / 2), 20) do
        for _, offset in ipairs({0, 1, 3, 7}) do
            for _, shadow in ipairs({false, true}) do
                local actual, painted = {}, 0
                for _, span in ipairs(Mask.spans(w, h, r, offset, shadow)) do
                    assert(span.width > 0 and span.x >= 0 and span.x + span.width <= w)
                    for x = span.x, span.x + span.width - 1 do
                        local key = span.y * w + x
                        assert(actual[key] == nil, "overlapping spans")
                        actual[key], painted = span.color, painted + 1
                    end
                end
                local expected = 0
                for y = 0, h - 1 do
                    for x = 0, w - 1 do
                        local corner = (x < r or x >= w-r) and (y < r or y >= h-r)
                        local color = corner and not inside(x, y, w, h, r)
                            and (shadow and inside(x-offset, y-offset, w, h, r) and "shadow" or "white") or nil
                        assert(actual[y*w+x] == color, "corner mask changed a pixel")
                        if color then expected = expected + 1 end
                    end
                end
                assert(painted == expected)
            end
        end
    end
end
local spans = Mask.spans(241, 301, 12, 3, true)
local pixels = 0
for _, span in ipairs(spans) do pixels = pixels + span.width end
assert(#spans < pixels, "corner pixels were not combined into fewer paint calls")
print("cover mask: pixel equivalence and merged paint calls verified")
