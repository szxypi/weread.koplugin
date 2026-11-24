-- Preserve original HTML rune offsets without preserving tags, images or CSS.
-- WeRead heat-map ranges address the source HTML, not the rendered EPUB text.
local Source = {}
local CHECKPOINT = 512
local MAX_CHECKPOINTS = 16384
local MAX_ENTITY_INTERVALS = 4096
-- Entries disappear with their span, and never retain the span as a value.
local checkpoints = setmetatable({}, { __mode = "k" })
local function length(byte)
    if byte < 128 then return 1 elseif byte < 224 then return 2
    elseif byte < 240 then return 3 else return 4 end
end

function Source.plain(text)
    text = text:gsub("^\239\187\191", "")
    local i, count = 1, 0
    while i <= #text do i, count = i + length(text:byte(i)), count + 1 end
    return { { 0, count, text, true } }
end

function Source.index(html, options)
    html = html:gsub("^\239\187\191", "")
    local spans, offset, i, start, start_byte = {}, 0, 1, nil, nil
    local in_tag, quote, suppressed = false, nil, nil
    local body_only, in_body = options and options.body_only == true, false
    local tag_start
    local function flush()
        -- A text span is contiguous in the original bytes. Slice once instead
        -- of collecting every UTF-8 character into a temporary table.
        if start then spans[#spans + 1] = { start, offset, html:sub(start_byte, i - 1) } end
        start, start_byte = nil, nil
    end
    while i <= #html do
        local size = length(html:byte(i))
        local char = html:sub(i, i + size - 1)
        if in_tag then
            if quote then
                if char == quote then quote = nil end
            elseif char == '"' or char == "'" then quote = char
            elseif char == ">" then
                in_tag = false
                local name = html:sub(tag_start, i):lower()
                if name:match('^body[%s>]') then in_body = true
                elseif name:match('^/body[%s>]') then in_body = false end
                if name:match("^/?script[%s>]") or name:match("^/?style[%s>]") then
                    suppressed = name:sub(1, 1) ~= "/" or nil
                end
            end
        elseif html:sub(i, i + 3) == "<!--" then
            flush()
            local ending = html:find("-->", i + 4, true)
            if not ending then return {} end
            local after = ending + 3
            while i < after do i, offset = i + length(html:byte(i)), offset + 1 end
            goto continue
        elseif char == "<" and html:sub(i + 1, i + 1):match("[%a/!?]") then
            flush()
            in_tag, tag_start = true, i + size
        elseif not suppressed and (not body_only or in_body) then
            start = start or offset
            start_byte = start_byte or i
        end
        i, offset = i + size, offset + 1
        ::continue::
    end
    flush()
    return spans
end

-- Large, repeatedly quoted spans otherwise rescan from byte one for every
-- range. Offsets are relative to the immutable string, so callers may still
-- adjust a span's source offset; replacing its text invalidates the cache.
local function seek(span, target)
    local text = span[3]
    local cache = checkpoints[span]
    if not cache or cache.text ~= text or cache.pending then
        cache = { text = text, bytes = { 1 }, count = 0, at = 1,
            has_amp = text:find('&', 1, true) ~= nil }
        if cache.has_amp then
            local intervals, at = {}, 1
            while true do
                local first = text:find('&', at, true)
                if not first then break end
                if #intervals >= MAX_ENTITY_INTERVALS * 2 then intervals = false; break end
                local last = text:find(';', first + 1, true) or (#text + 1)
                intervals[#intervals + 1], intervals[#intervals + 2] = first, last
                at = last + 1
            end
            cache.entities = intervals
        end
        checkpoints[span] = cache
    end
    local wanted = math.floor(target / CHECKPOINT)
    while #cache.bytes <= wanted and #cache.bytes < MAX_CHECKPOINTS and cache.at <= #text do
        cache.at = cache.at + length(text:byte(cache.at))
        cache.count = cache.count + 1
        if cache.count % CHECKPOINT == 0 then cache.bytes[#cache.bytes + 1] = cache.at end
    end
    local slot = math.min(wanted + 1, #cache.bytes)
    return span[1] + (slot - 1) * CHECKPOINT, cache.bytes[slot]
end

local function open_entity_before(cache, at)
    local entities = cache.entities
    local lo, hi = 1, #entities / 2
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if entities[mid * 2 - 1] < at then lo = mid + 1 else hi = mid - 1 end
    end
    return hi > 0 and at <= entities[hi * 2]
end

function Source.quote(spans, range)
    local first, last = tostring(range):match("^(%d+)%-(%d+)$")
    first, last = tonumber(first), tonumber(last)
    if not first or not last or first >= last then return "" end
    local pieces = {}
    for _, span in ipairs(spans or {}) do
        if span[1] < last and span[2] > first then
            local offset, i, start_byte = span[1], 1, nil
            if #span[3] >= 4096 and first - offset >= CHECKPOINT then
                local cache = checkpoints[span]
                if cache and cache.text == span[3] then
                    offset, i = seek(span, first - offset)
                else
                    -- Single lookups need no full-text cache preparation.
                    checkpoints[span] = { text = span[3], pending = true }
                end
            end
            while i <= #span[3] and offset < last do
                if offset >= first and not start_byte then start_byte = i end
                i, offset = i + length(span[3]:byte(i)), offset + 1
            end
            if start_byte then
                local text = span[3]:sub(start_byte, i - 1)
                -- A cut entity cannot be interpreted safely.
                if span[4] then
                    pieces[#pieces + 1] = text
                else
                    local cache = checkpoints[span]
                    if not cache or cache.text ~= span[3] or cache.pending or cache.has_amp then
                        if text:match("&[^;]*$") then return "" end
                        if cache and cache.text == span[3] and cache.entities then
                            if open_entity_before(cache, start_byte) then return "" end
                        elseif span[3]:sub(1, start_byte - 1):match("&[^;]*$") then return "" end
                    end
                    pieces[#pieces + 1] = require("util").htmlEntitiesToUtf8(text)
                end
            end
        end
    end
    return table.concat(pieces)
end
return Source
