-- Private captured-pipe comparison only: no credentials, network or files.
require('setupkoenv')
local root=arg[1] or '/source';package.path=root..'/?.lua;'..package.path
local json=require('json');local Model=require('weread.lib.readtime_statistics')
local raw=assert(io.stdin:read('*a'));assert(#raw<=256*1024)
local input=json.decode(raw);assert(type(input)=='table' and type(input.options)=='table' and #input.options==2)
for k in pairs(input) do assert(k=='options' or k=='observed') end
local option_count=0
for k in pairs(input.options) do assert(k==1 or k==2);option_count=option_count+1 end
assert(option_count==2)
local out={matching_candidates=0,removed_zero_buckets=0,read_days_delta=0}
for i,v in ipairs(input.options) do
    local result=Model.compare(v,input.observed)
    if result then
        out.matching_candidates=out.matching_candidates+1;out.removed_zero_buckets=result.removed_zero_buckets;out.read_days_delta=i-1
    end
end
io.stdout:write('\nWEREAD_READTIME_STATISTICS='..json.encode(out)..'\n')
