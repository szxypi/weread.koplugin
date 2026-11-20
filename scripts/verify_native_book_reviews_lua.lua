-- Receives fixture or private input on stdin; stdout is a private comparison pipe.
local json = require('json')
local Data = require('weread.lib.native_book_reviews')
local raw = io.read('*a')
local input = json.decode(raw)
local client = {json_decode = function(_, value) return json.decode(value) end}
local output = {}
for _, sample in ipairs(input.samples) do
    local first = Data.project(client, sample.first, sample.book_id, 20)
    local second = Data.project(client, sample.second, sample.book_id, 40, first.ids)
    output[#output + 1] = {first = first, second = second}
end
io.write(json.encode({samples = output}))
