-- Web Reader coordinate runs, validated by verify_source_coordinates.py against
-- the official parser on 2026-11-08. References MiuRead wr_co/source_position
-- (AGPL-3.0-only), with retained-tag resets rather than raw-XHTML extrapolation.
-- Pure local mapping: no network, persistence or progress-upload activation.
local M = { MAX_BYTES = 2 * 1024 * 1024, MAX_ANCHOR_BYTES = 8192, SCHEMA = 1 }
local Source = require('weread.lib.position_source')
local Map = {}
Map.__index = Map
local retained = {}
for name in ("abbr address area article aside audio b bdi bdo big blockquote body br caption center cite code col colgroup "
    .. "dd del details div dl dt em font footer h1 h2 h3 h4 h5 h6 header hr i img ins li mark nav ol p pre s section "
    .. "small span strong sub sup table tbody td tfoot th thead tr tt u ul video"):gmatch("%S+") do retained[name] = true end

local function fail(reason) error("source_coordinates/" .. reason, 0) end

-- Validate scalars while counting JavaScript UTF-16 units. No per-rune table
-- for the complete chapter: a long chapter must remain bounded on Kindle.
local function scalar(text, at)
    local a, b, c, d = text:byte(at, at + 3)
    if not a then fail("invalid_utf8") end
    if a < 128 then return a, 1, 1 end
    local function continuation(value) return value and value >= 128 and value <= 191 end
    if a >= 194 and a <= 223 and continuation(b) then return (a - 192) * 64 + b - 128, 2, 1 end
    if a >= 224 and a <= 239 and continuation(b) and continuation(c)
        and (a ~= 224 or b >= 160) and (a ~= 237 or b < 160) then
        return (a - 224) * 4096 + (b - 128) * 64 + c - 128, 3, 1
    end
    if a >= 240 and a <= 244 and continuation(b) and continuation(c) and continuation(d)
        and (a ~= 240 or b >= 144) and (a ~= 244 or b <= 143) then
        return (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128, 4, 2
    end
    fail("invalid_utf8")
end

local function units(text, xml)
    local at, count = 1, 0
    while at <= #text do
        local cp, width, n = scalar(text, at)
        if xml and cp < 32 and cp ~= 9 and cp ~= 10 and cp ~= 13 then fail("invalid_xml_control") end
        at, count = at + width, count + n
    end
    return count
end

local function whitespace(cp)
    return (cp >= 9 and cp <= 13) or (cp >= 28 and cp <= 32) or cp == 133 or cp == 160
        or cp == 5760 or (cp >= 8192 and cp <= 8202) or cp == 8232 or cp == 8233
        or cp == 8239 or cp == 8287 or cp == 12288
end

local function normalized(text)
    if type(text) ~= "string" or #text > M.MAX_ANCHOR_BYTES then fail("invalid_anchor") end
    local pieces, at, count = {}, 1, 0
    while at <= #text do
        local cp, width = scalar(text, at)
        if not whitespace(cp) then
            pieces[#pieces + 1], count = text:sub(at, at + width - 1), count + 1
        end
        at = at + width
    end
    return table.concat(pieces), count
end

local xml_entities = { ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"', ["&apos;"] = "'", ["&nbsp;"] = " " }
local function encode(cp)
    if cp < 0 or cp > 1114111 or (cp >= 55296 and cp <= 57343) then fail("invalid_entity") end
    if (cp < 32 and cp ~= 9 and cp ~= 10 and cp ~= 13) or cp == 65534 or cp == 65535 then fail("invalid_entity") end
    if cp < 128 then return string.char(cp) end
    if cp < 2048 then return string.char(192 + math.floor(cp / 64), 128 + cp % 64) end
    if cp < 65536 then return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64) end
    return string.char(240 + math.floor(cp / 262144), 128 + math.floor(cp / 4096) % 64,
        128 + math.floor(cp / 64) % 64, 128 + cp % 64)
end

local function decode_entity(entity)
    if xml_entities[entity] then return xml_entities[entity] end
    local decimal, hex = entity:match("^&#(%d+);$"), entity:match("^&#[xX](%x+);$")
    if decimal or hex then
        local cp = tonumber(decimal or hex, decimal and 10 or 16)
        if not cp or cp % 1 ~= 0 then fail("invalid_entity") end
        return encode(cp)
    end
    local decoded = require("util").htmlEntitiesToUtf8(entity)
    if decoded == entity then fail("unknown_entity") end
    return decoded
end

local function tag_end(raw, start)
    local at, quote, brackets = start + 1, nil, 0
    local declaration = raw:sub(start, start + 1) == "<!"
    while at <= #raw do
        local char = raw:sub(at, at)
        if quote then
            if char == quote then quote = nil end
        elseif char == '"' or char == "'" then quote = char
        elseif declaration and char == "[" then brackets = brackets + 1
        elseif declaration and char == "]" then brackets = math.max(0, brackets - 1)
        elseif char == ">" and brackets == 0 then return at end
        at = at + 1
    end
    fail("incomplete_tag")
end

local function parse(raw, options)
    if type(raw) ~= "string" or #raw > M.MAX_BYTES or not raw:find("<body", 1, true) then fail("invalid_source") end
    local first, body_closing = raw:find("<body", 1, true), raw:find("</body", 1, true)
    if not body_closing or raw:find("<body", first + 5, true) or raw:find("</body", body_closing + 6, true) then
        fail("multiple_or_incomplete_bodies")
    end
    local map = setmetatable({ segments = {}, decode = options and options.decode_entity or decode_entity }, Map)
    local at, co, base, body, seen, raw_text = 1, 0, 0, false, false, nil
    local pieces = {}
    local function flush()
        if #pieces > 0 then
            map.segments[#map.segments + 1] = { base, table.concat(pieces) }
            pieces = {}
        end
    end
    local function consume(last)
        co, at = co + units(raw:sub(at, last), true), last + 1
    end
    local lower -- allocated only for raw-text elements
    while at <= #raw do
        if raw_text then
            lower = lower or raw:lower()
            local ending = lower:find("</" .. raw_text .. "%s*>", at)
            if not ending then fail("incomplete_raw_text") end
            local data = raw:sub(at, ending - 1)
            if body then
                if data:find("<", 1, true) then fail("unsupported_raw_text_markup") end
                pieces[#pieces + 1] = data:gsub("<", "&lt;"):gsub(">", "&gt;")
            end
            if ending > at then consume(ending - 1) end
            raw_text = nil
        elseif raw:sub(at, at + 3) == "<!--" then
            local ending = raw:find("-->", at + 4, true)
            if not ending then fail("incomplete_comment") end
            consume(ending + 2) -- filtered comments consume no coordinate-run width
        elseif raw:sub(at, at + 8) == "<![CDATA[" then
            if body then fail("unsupported_declaration") end
            local ending = raw:find("]]>", at + 9, true)
            if not ending then fail("unsupported_declaration") end
            consume(ending + 2)
        elseif raw:sub(at, at) == "<" and raw:sub(at + 1, at + 1):match("[%a/!?]") then
            local ending = tag_end(raw, at)
            local tag = raw:sub(at, ending)
            local closing, name = tag:match("^<(/?)([%a][%w:_-]*)[%s/>]")
            if not name then
                if body then fail("unsupported_declaration") end
                consume(ending)
            else
                name = name:lower()
                local self_closing = tag:match("/%s*>$") ~= nil
                if name == "body" and closing == "" then
                    if seen or self_closing then fail("multiple_or_incomplete_bodies") end
                    body, seen = true, true
                end
                local is_retained = body and retained[name]
                if is_retained then flush() end
                consume(ending)
                if is_retained then base = co end
                if name == "body" and closing == "/" then body = false end
                if closing == "" and not self_closing and (name == "script" or name == "style") then raw_text = name end
            end
        else
            local ending = raw:find("<", at + 1, true)
            local last = ending and ending - 1 or #raw
            local data = raw:sub(at, last)
            if body then pieces[#pieces + 1] = data:gsub("<", "&lt;"):gsub(">", "&gt;") end
            consume(last)
        end
    end
    if not seen or body then fail("incomplete_body") end
    flush()
    return map
end

function Map:_token(text, at)
    if not self.literal and text:sub(at, at) == "&" and text:sub(at + 1, at + 1):match("[%a#]") then
        local ending = text:find(";", at + 1, true)
        if not ending or ending - at > 64 then fail("invalid_entity") end
        local entity = text:sub(at, ending)
        if not entity:match("^&[%w#]+;$") then fail("invalid_entity") end
        local ok, decoded = pcall(self.decode, entity)
        if not ok or type(decoded) ~= "string" then fail("entity_decode_failed") end
        local clean = normalized(decoded)
        return clean, ending + 1, ending - at + 1
    end
    local cp, width, n = scalar(text, at)
    if self.literal and cp < 32 and cp ~= 9 and cp ~= 10 and cp ~= 13 then fail('invalid_xml_control') end
    return whitespace(cp) and "" or text:sub(at, at + width - 1), at + width, n
end

function Map:_index()
    if self.flat then return end
    local chunks, points, total = {}, {}, 0
    for index, segment in ipairs(self.segments) do
        local co, text, at, pieces, count = segment[1], segment[2], 1, {}, 0
        local function checkpoint()
            if #pieces > 0 then chunks[#chunks + 1] = table.concat(pieces) pieces, count = {}, 0 end
            points[#points + 1] = { flat = total + 1, segment = index, at = at, co = co }
        end
        checkpoint()
        while at <= #text do
            local clean, next_at, n = self:_token(text, at)
            if clean ~= "" then pieces[#pieces + 1], count, total = clean, count + 1, total + #clean end
            at, co = next_at, co + n
            if count >= 256 then checkpoint() end
        end
        if #pieces > 0 then chunks[#chunks + 1] = table.concat(pieces) end
    end
    self.flat, self.points = table.concat(chunks), points
end

function Map:_point(byte, ending)
    self:_index()
    local low, high = 1, #self.points
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if self.points[middle].flat <= byte then low = middle + 1 else high = middle - 1 end
    end
    local point = self.points[high]
    if not point then fail("visible_boundary_missing") end
    local at, co, flat = point.at, point.co, point.flat
    local text = self.segments[point.segment][2]
    while at <= #text do
        local clean, next_at, n = self:_token(text, at)
        if #clean > 0 and byte < flat + #clean then
            if ending then
                if byte ~= flat + #clean - 1 then fail("inside_entity_or_scalar") end
                return co + n
            end
            if byte ~= flat then fail("inside_entity_or_scalar") end
            return co
        end
        at, co, flat = next_at, co + n, flat + #clean
    end
    fail("visible_boundary_missing")
end

function Map:locate(text, before, after)
    local ok, result = pcall(function()
        self:_index()
        local needle, count = normalized(text)
        local prefix, suffix = normalized(before or ""), normalized(after or "")
        if count < 12 then fail("anchor_too_short") end
        local from, selected = 1, nil
        while true do
            local first = self.flat:find(needle, from, true)
            if not first then break end
            local last = first + #needle - 1
            if (prefix == "" or self.flat:sub(math.max(1, first - #prefix), first - 1) == prefix)
                and (suffix == "" or self.flat:sub(last + 1, last + #suffix) == suffix) then
                if selected then fail("anchor_ambiguous") end
                selected = { first = first, last = last }
            end
            from = first + 1 -- include overlapping occurrences
        end
        if not selected then fail("anchor_missing") end
        selected.co, selected.end_co = self:_point(selected.first), self:_point(selected.last, true)
        selected.basis = self.basis
        return selected
    end)
    if ok then return result end
    return nil, type(result) == "string" and result:match("^source_coordinates/[a-z_]+$") or "source_coordinates/unavailable"
end

-- Locate a scalar boundary inside a unique normalized quotation. DOM capture
-- needs the position within context, including the chapter's final boundary;
-- adding scalar counts to a UTF-16/XML source offset is never equivalent.
function Map:locate_point(text, point_offset, before, after)
    local ok, result = pcall(function()
        local clean, count = normalized(text)
        if type(point_offset) ~= "number" or point_offset ~= point_offset or point_offset % 1 ~= 0
            or point_offset < 0 or point_offset > count then fail("invalid_point") end
        local found, reason = self:locate(clean, before, after)
        if not found then error(reason, 0) end
        local co = found.end_co
        if point_offset < count then
            local at = 1
            for _i = 1, point_offset do local width = select(2, scalar(clean, at)) at = at + width end
            co = self:_point(found.first + at - 1)
        end
        return { co = co, point_offset = point_offset, basis = self.basis }
    end)
    if ok then return result end
    return nil, type(result) == "string" and result:match("^source_coordinates/[a-z_]+$") or "source_coordinates/unavailable"
end

function Map:anchor(co)
    local ok, result = pcall(function()
        if type(co) ~= "number" or co ~= co or co % 1 ~= 0 or co < 0 or co > M.MAX_BYTES * 8 then fail("invalid_offset") end
        self:_index()
        local candidates, interior, flat = {}, false, 1
        local function candidate(byte, visible)
            candidates[byte] = candidates[byte] == true or visible
        end
        for _, segment in ipairs(self.segments) do
            local cursor, text, at = segment[1], segment[2], 1
            while at <= #text do
                local clean, next_at, n = self:_token(text, at)
                if co == cursor then candidate(flat, clean ~= "") end
                if co == cursor + n and clean ~= "" then candidate(flat + #clean, true) end
                if co > cursor and co < cursor + n then interior = true end
                at, cursor, flat = next_at, cursor + n, flat + #clean
            end
        end
        local byte, count, visible
        count = 0
        for at, shown in pairs(candidates) do byte, visible, count = at, shown, count + 1 end
        if count > 1 or (count > 0 and interior) then fail("offset_ambiguous") end
        if interior then fail("inside_entity_or_scalar") end
        if count == 0 or not visible then fail("visible_boundary_missing") end
        local function previous(at)
            at = at - 1
            while at > 1 and self.flat:byte(at) >= 128 and self.flat:byte(at) < 192 do at = at - 1 end
            return at
        end
        for _, width in ipairs({ 24, 48, 96, 192 }) do
            local first, after = byte, byte
            for _i = 1, width do
                if first > 1 then first = previous(first) end
                if after <= #self.flat then local size = select(2, scalar(self.flat, after)) after = after + size end
            end
            -- A multi-character entity has only one source interval. Expand
            -- the search window to its boundaries, never invent an inner co.
            while first > 1 and not pcall(self._point, self, first) do first = previous(first) end
            while after <= #self.flat and not pcall(self._point, self, after - 1, true) do
                local size = select(2, scalar(self.flat, after))
                after = after + size
            end
            local quote = self.flat:sub(first, after - 1)
            local found, reason = self:locate(quote)
            if found and found.first == first then
                local at, offset = first, 0
                while at < byte do local size = select(2, scalar(self.flat, at)) at, offset = at + size, offset + 1 end
                return { co = co, text = quote, point_offset = offset, point_unit = "unicode_scalars",
                    basis = self.basis }
            elseif reason ~= "source_coordinates/anchor_too_short" and reason ~= "source_coordinates/anchor_ambiguous" then
                fail("reverse_anchor_unavailable")
            end
        end
        fail("reverse_anchor_ambiguous_or_short")
    end)
    if ok then return result end
    return nil, type(result) == "string" and result:match("^source_coordinates/[a-z_]+$") or "source_coordinates/unavailable"
end

function M.build(raw, options)
    local ok, result = pcall(function()
        local format = options and options.format or 'web_xhtml'
        local basis = Source.coordinate_basis(format)
        if not basis then fail('invalid_source') end
        local map
        if format == 'web_txt' then
            if type(raw) ~= 'string' or #raw == 0 or #raw > M.MAX_BYTES then fail('invalid_source') end
            map = setmetatable({segments={{0,raw}}, literal=true}, Map)
        else map = parse(raw, options) end
        map.basis = basis
        map:_index()
        return map
    end)
    if ok then return result end
    return nil, type(result) == "string" and result:match("^source_coordinates/[a-z_]+$") or "source_coordinates/unavailable"
end

return M
