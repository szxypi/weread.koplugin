package.path='./?.lua;'..package.path
local ffi=require('ffi')
local previous_ffi,previous_util=package.loaded.ffi,package.loaded['ffi/util']
local output,closed,attempts,fail={},0,0,false
local libc={EINTR=4,write=function(_fd,buffer,remaining)
    attempts=attempts+1
    if fail then ffi.errno(32);return -1 end
    if attempts==1 then ffi.errno(4);return -1 end
    local n=math.min(tonumber(remaining),4096)
    if attempts%4==0 then collectgarbage('collect') end
    output[#output+1]=ffi.string(buffer,n)
    return n
end,close=function() closed=closed+1;return 0 end}
package.loaded.ffi=setmetatable({C=libc},{__index=ffi})
local launch
package.loaded['ffi/util']={runInSubProcess=function(fn) launch=fn;return 42,43 end,
    getNonBlockingReadSize=function() return 0 end,isSubProcessDone=function() return false end,
    terminateSubProcess=function() end}
package.loaded['weread.lib.memory_worker']=nil
local Worker=require('weread.lib.memory_worker')
local scheduler={scheduleIn=function() end,unschedule=function() end}
local codec={json_encode=function(_,value) return value end,json_decode=function() return {} end}
local data=string.rep('synthetic\0bytes\255',12000)
local worker=Worker:new{scheduler=scheduler,codec=codec,max_bytes=262144}
assert(worker:start(function(progress) progress(10);return data end,function() end,function() end))
launch(42,43)
assert(table.concat(output)=='p10\nr'..data and closed==1 and attempts>30,
    'partial writes, interrupted calls or binary data changed')
output,closed,attempts,fail={},0,0,true
worker=Worker:new{scheduler=scheduler,codec=codec,max_bytes=262144}
assert(worker:start(function() return data end,function() end,function() end))
launch(42,43)
assert(#output==0 and closed==1 and attempts==1,'failed result prefix sent data or leaked the descriptor')
package.loaded.ffi,package.loaded['ffi/util']=previous_ffi,previous_util
package.loaded['weread.lib.memory_worker']=nil
print('memory_worker_pipe_spec: partial writes, EINTR, GC pinning and prefix failure passed')
