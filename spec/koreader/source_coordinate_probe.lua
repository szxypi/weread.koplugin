-- Memory-only protocol comparison in the real KOReader Lua/JSON environment.
require("ffi").log = function() end
require("setupkoenv")
local root = assert(arg[1], "repository path required")
package.path = root .. "/?.lua;" .. package.path
local Source = require("weread.lib.source_coordinates")
local json = require("rapidjson")
local input = assert(io.stdin:read(16 * 1024 * 1024 + 1))
assert(#input <= 16 * 1024 * 1024, "probe input too large")
local payload = json.decode(input)
assert(type(payload) == "table" and type(payload.sources) == "table" and #payload.sources <= 64, "invalid probe input")
local maps = json.array{}
for index, source in ipairs(payload.sources) do
    local map = assert(Source.build(source.html,{format=source.format or 'web_xhtml'}))
    local positions, scalar_positions = json.array{}, json.array{}
    for query, quote in ipairs(source.queries) do
        local position = assert(map:locate(quote))
        positions[query] = { co = position.co, end_co = position.end_co }
        local count = 0
        for _character in quote:gmatch("[%z\1-\127\194-\244][\128-\191]*") do count = count + 1 end
        scalar_positions[query] = json.array{}
        for i, offset in ipairs({ 0, math.floor(count / 2), count }) do
            local point = assert(map:locate_point(quote, offset))
            scalar_positions[query][i] = { co = point.co, point_offset = offset }
        end
    end
    local target
    if source.target_co ~= nil then
        target = assert(map:anchor(source.target_co))
        local roundtrip = assert(map:locate_point(target.text, target.point_offset))
        assert(roundtrip.co == source.target_co, "current target did not roundtrip")
    end
    maps[index] = { basis=map.basis, segments = json.array(map.segments), flat = map.flat, positions = positions,
        scalar_positions = scalar_positions, target_anchor = target }
end
io.stdout:write(json.encode({ maps = maps }))
