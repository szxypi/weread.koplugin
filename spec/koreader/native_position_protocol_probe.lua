-- Private memory pipes; no network, settings or ordinary output artifacts.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json');local output={result='UNVERIFIED'}
local ok,value=pcall(function()
    assert(type(arg[1])=='string');package.path=arg[1]..'/?.lua;'..package.path
    local raw=assert(io.stdin:read(65537));assert(#raw<=65536);local input=json.decode(raw)
    local P=require('weread.lib.native_position_protocol')
    local result={result='PASS',body=P.body(input.credentials,input.point,input.version,input.guest,input.now,input.random,
        input.time_zone,input.chapter_progress,json.decode('[]'))}
    if input.native_response~=nil then result.snapshot=P.snapshot(input.native_response,input.point.book_id) end
    return result
end)
if ok then output=value end
io.stdout:write(json.encode(output));io.stdout:flush();os.exit(ok and 0 or 1)
