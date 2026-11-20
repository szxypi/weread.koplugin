-- Private input only. Output contains counts and a boolean, never catalog data.
require('setupkoenv')
local json=require('json')
local raw=assert(io.stdin:read('*a'));assert(#raw<=8*1024*1024)
local input=json.decode(raw);local Content=require('weread.lib.content')
assert(type(input)=='table' and type(input.samples)=='table' and #input.samples<=8)
local total,excluded=0,0
for _i,sample in ipairs(input.samples) do
    assert(type(sample.rows)=='table' and type(sample.expected)=='table' and #sample.rows==#sample.expected)
    local actual=Content.readable_chapters(sample.rows)
    local index=1
    for i,row in ipairs(sample.rows) do
        local expected=sample.expected[i]
        assert(type(expected)=='boolean')
        if expected then assert(actual[index]==row);index=index+1 else excluded=excluded+1 end
        total=total+1
    end
    assert(index==#actual+1)
end
io.stdout:write('\nWEREAD_CB_READABLE_CATALOG='..json.encode({matches=true,catalogs=#input.samples,
    total_rows=total,excluded_rows=excluded})..'\n')
