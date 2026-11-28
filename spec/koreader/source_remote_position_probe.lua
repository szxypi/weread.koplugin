-- Private response/catalog comparison only; no network or credentials.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local ok,result=pcall(function()
    local raw=io.stdin:read(4*1024*1024+1);assert(#raw<=4*1024*1024)
    local input=json.decode(raw);assert(type(input.samples)=='table' and #input.samples>0 and #input.samples<=32)
    local resolve=require('weread.lib.source_remote_position').resolve;local out=json.decode('[]')
    for _i,s in ipairs(input.samples) do
        local p,reason=resolve(s.raw,s.book_id,s.chapters,s.source)
        out[#out+1]=p and {ok=true,position=p} or {ok=false,reason=reason}
    end
    return out
end)
io.stdout:write('\nWEREAD_SOURCE_REMOTE_RESULT='..json.encode(ok and result or {error='model_failed'})..'\n')
os.exit(ok and 0 or 1)
