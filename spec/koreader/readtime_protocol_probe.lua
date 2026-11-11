-- Private stdin/stdout only: no files, UI, authentication or network dispatch.
require('ffi').log=function() end
require('setupkoenv')
local raw=io.stdin:read(65537);local result={result='UNVERIFIED'}
local ok,value=pcall(function()
    assert(type(raw)=='string' and #raw>0 and #raw<=65536 and type(arg[1])=='string')
    package.path=arg[1]..'/?.lua;'..package.path
    local Json=require('json');local input=Json.decode(raw)
    local expected={credentials=true,book_id=true,rows=true,guest_token=true,config_token=true,now=true,random=true,envelope=true}
    local count=0;for k in pairs(input) do assert(expected[k]);count=count+1 end;assert(count==8)
    local body=require('weread.lib.readtime_protocol').batch(input.credentials,input.book_id,input.rows,
        input.guest_token,input.config_token,input.now,input.random,input.envelope)
    return {result='PASS',body=body}
end)
if ok then result=value end
io.stdout:write(require('json').encode(result));io.stdout:flush()
os.exit(ok and 0 or 1)
