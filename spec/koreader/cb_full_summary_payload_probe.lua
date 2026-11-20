-- Compare private payloads in memory; no client, credentials or network access.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local Json=require('json')
local ok,result=pcall(function()
    local raw=io.stdin:read(65537);assert(#raw<=65536)
    local input=Json.decode(raw);assert(type(input.samples)=='table' and #input.samples>=1 and #input.samples<=16)
    local out={matches=0,total=#input.samples,network_requests=0}
    local Payload=require('weread.lib.cb_position_payload')
    for _i,sample in ipairs(input.samples) do
        local actual=Payload.build(sample.stage,sample.options);local same=true
        for key,value in pairs(actual) do if sample.expected[key]~=value or type(sample.expected[key])~=type(value) then same=false end end
        for key in pairs(sample.expected) do if actual[key]==nil then same=false end end
        if same then out.matches=out.matches+1 end
    end
    return out
end)
print('\nWEREAD_CB_FULL_SUMMARY_PAYLOAD='..Json.encode(ok and result or {error='unverified'}))
os.exit(ok and 0 or 1)
