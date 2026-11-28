-- Compare four real-context wire bodies through captured memory only.
-- There is no Client, Cookie, HTTP transport or credential persistence here.
require("setupkoenv")
package.path = assert(arg[1]) .. "/?.lua;" .. package.path
local Json = require("json")
local Protocol = require("weread.lib.protocol")
local raw = io.stdin:read(65537)
local ok, result = pcall(function()
    assert(#raw <= 65536)
    local input = Json.decode(raw); raw = nil
    assert(type(input.samples) == "table" and #input.samples >= 3 and #input.samples <= 4)
    local output = { stages = Json.decode("[]"), http_requests = 0 }
    for _i, sample in ipairs(input.samples) do
        assert(({ write_enter = true, write_same = true, write_probe = true, write_restore = true })[sample.stage])
        local body = (sample.stage == "write_enter" and Protocol.make_enter_read_payload or Protocol.make_read_payload)(sample.options)
        local mismatched, seen = Json.decode("[]"), {}
        for key, expected in pairs(sample.expected) do
            if type(body[key]) ~= type(expected) or body[key] ~= expected then mismatched[#mismatched + 1] = key; seen[key] = true end
        end
        for key in pairs(body) do
            if sample.expected[key] == nil and not seen[key] then mismatched[#mismatched + 1] = key end
        end
        table.sort(mismatched)
        output.stages[#output.stages + 1] = { stage = sample.stage, matches = #mismatched == 0, mismatched_fields = mismatched }
    end
    return output
end)
io.stdout:write("\nWEREAD_POSITION_PAYLOAD_RESULT=" .. Json.encode(ok and result or { error = "model_failed" }) .. "\n")
os.exit(ok and 0 or 1)
