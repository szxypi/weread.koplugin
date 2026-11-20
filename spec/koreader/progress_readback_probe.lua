-- Captured private model comparison. No Client or HTTP in this process.
require("setupkoenv")
package.path = assert(arg[1]) .. "/?.lua;" .. package.path
local Json = require("json")
local Model = require("weread.lib.progress_readback")
local ok, result = pcall(function()
    local raw = io.stdin:read(256 * 1024 + 1)
    assert(#raw <= 256 * 1024)
    local input = Json.decode(raw)
    assert(type(input.samples) == "table" and #input.samples > 0 and #input.samples <= 24)
    local rows = Json.decode("[]")
    for _i, sample in ipairs(input.samples) do rows[#rows + 1] = Model.check(sample.raw, sample.target) end
    return rows
end)
io.stdout:write("\nWEREAD_PROGRESS_READBACK_RESULT=" .. Json.encode(ok and result or { error = "comparison_failed" }) .. "\n")
os.exit(ok and 0 or 1)
