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
    local map = assert(Source.build(source.html))
    local positions = json.array{}
    for query, quote in ipairs(source.queries) do
        local position = assert(map:locate(quote))
        positions[query] = { co = position.co, end_co = position.end_co }
    end
    maps[index] = { segments = json.array(map.segments), flat = map.flat, positions = positions }
end
io.stdout:write(json.encode({ maps = maps }))
