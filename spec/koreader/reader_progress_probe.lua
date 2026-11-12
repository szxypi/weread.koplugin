-- Private response/model comparison only. No credentials or HTTP are used.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local ok,result=pcall(function()
    local raw=io.stdin:read(1024*1024+1);assert(#raw<=1024*1024)
    local input=json.decode(raw)
    assert(type(input.samples)=='table' and #input.samples>0 and #input.samples<=128)
    local output=json.decode('[]')
    local Mapper=require('weread.lib.position_mapper')
    for _i,sample in ipairs(input.samples) do
        local position,reason=Mapper.normalize_remote(sample.raw,sample.book_id,'web',{})
        output[#output+1]=position and {ok=true,position=position} or {ok=false,reason=reason}
    end
    return output
end)
io.stdout:write('\nWEREAD_READER_PROGRESS_RESULT='..json.encode(ok and result or {error='model_failed'})..'\n')
os.exit(ok and 0 or 1)
