-- Exact native text endpoints, including punctuation-only final pages.
-- No navigation, network, persistence or word-boundary extrapolation.
local M = { MAX_STEPS = 65536, MAX_BYTES = 8 * 1024 * 1024 }
local function fail(reason) error("document_text_end/" .. reason, 0) end
local function fragment(point)
    return type(point) == "string" and (point:match("^(/body/DocFragment%[%d+%])")
        or point:match("^(/body/DocFragment)[/%.]") or point == "/body/DocFragment" and point) or nil
end
local function protected(task)
    local ok, value = pcall(task)
    if ok then return value end
    return nil, type(value) == "string" and value:match("^document_text_end/[a-z_]+$") or "document_text_end/unavailable"
end
local function node(document, point, options)
    if type(point) ~= "string" or options.root and fragment(point) ~= options.root then fail("chapter_end_unavailable") end
    local prefix = point:match("^(.-)%.%d+$")
    if not prefix or not prefix:find("/text()", 1, true) then fail("chapter_end_unavailable") end
    local text = document:getTextFromXPointer(point)
    if type(text) ~= "string" or #text > (options.max_bytes or M.MAX_BYTES) then fail("text_limit") end
    local at, count = 1, 0
    local function tail(n) return n and n >= 128 and n <= 191 end
    while at <= #text do
        local a, b, c, d = text:byte(at, at + 3)
        local width
        if a < 128 then width = 1
        elseif a >= 194 and a <= 223 and tail(b) then width = 2
        elseif a >= 224 and a <= 239 and tail(b) and tail(c) and (a ~= 224 or b >= 160) and (a ~= 237 or b < 160) then width = 3
        elseif a >= 240 and a <= 244 and tail(b) and tail(c) and tail(d) and (a ~= 240 or b >= 144) and (a ~= 244 or b <= 143) then width = 4
        else fail("invalid_utf8") end
        at, count = at + width, count + 1
        if options.yield and count % 2048 == 0 then options.yield() end
    end
    local ending = document:getNormalizedXPointer(prefix .. "." .. count)
    if type(ending) ~= "string" or options.root and fragment(ending) ~= options.root then fail("chapter_end_unavailable") end
    return ending
end
function M.node(document, point, options)
    return protected(function() return node(document, point, options or {}) end)
end
function M.supports(document)
    for _i, method in ipairs({ "getPageCount", "getPageXPointer", "getPrevVisibleChar", "getNextVisibleChar",
        "getTextFromXPointer", "getNormalizedXPointer" }) do
        if type(document[method]) ~= "function" then return false end
    end
    return true
end
function M.last(document, options)
    options = options or {}
    return protected(function()
        if not M.supports(document) then fail("unavailable") end
        local cursor = document:getPageXPointer(document:getPageCount())
        if type(cursor) ~= "string" then fail("chapter_end_unavailable") end
        cursor = document:getPrevVisibleChar(cursor) or cursor
        local ending
        for step = 1, options.max_steps or M.MAX_STEPS do
            if (not options.root or fragment(cursor) == options.root) and cursor:find("/text()", 1, true) then ending = cursor end
            local next_point = document:getNextVisibleChar(cursor)
            if not next_point then
                if not ending then fail("chapter_end_unavailable") end
                return node(document, ending, options)
            end
            if type(next_point) ~= "string" or next_point == cursor then fail("walk_diverged") end
            cursor = next_point
            if options.yield and step % 128 == 0 then options.yield() end
        end
        fail("chapter_end_limit")
    end)
end
return M
