require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local banner=require('ui/widget/infomessage'):new{text='Synthetic worker transfer'}
UI:show(banner);UI:forceRePaint()
local socket=require('socket')
local Crypto=require('weread.lib.crypto')
local Worker=arg[1]=='baseline' and assert(loadfile(arg[2]))() or require('weread.lib.memory_worker')
local streaming=arg[3]=='stream'
local size=assert(tonumber(arg[4]))
local pattern='Synthetic WeRead worker content 0123456789\n'
local payload=pattern:rep(math.ceil(size/#pattern)):sub(1,size)
local codec={json_encode=function(_,value) return value end,
    json_decode=function(_,value) return {size=#value,digest=Crypto.sha256_hex(value)} end}
local worker=Worker:new{scheduler=UI,codec=codec,max_bytes=size,timeout=60}
local result,updates,heartbeat,max_gap=nil,{},0,0
local started,last=socket.gettime(),socket.gettime()
local beat
beat=function()
    if result then return end
    local now=socket.gettime();heartbeat=heartbeat+1;max_gap=math.max(max_gap,now-last);last=now
    UI:scheduleIn(0.05,beat)
end
UI:scheduleIn(0.05,beat)
assert(worker:start(function(report)
    if streaming then for _,value in ipairs({0,10,50,100}) do report(value) end end
    return payload
end,function(value) result=value or {failed=true} end,streaming and function(value) updates[#updates+1]=value end or nil))
local deadline=started+30
while not result do
    assert(socket.gettime()<deadline,'worker deadline exceeded')
    UI:setInputTimeout(0);UI:handleInput();socket.sleep(0.001)
end
local elapsed=socket.gettime()-started
UI:unschedule(beat)
UI:close(banner)
assert(result.size==size and result.digest==Crypto.sha256_hex(payload),'worker output changed')
assert(not streaming or table.concat(updates,',')=='0,10,50,100','progress frames changed')
assert(heartbeat>0 and max_gap<1.5,'UI event loop stalled')
print('\nWEREAD_WORKER_BENCHMARK='..require('json').encode({result='PASS',seconds=elapsed,bytes=result.size,
    digest=result.digest,progress=updates,heartbeat=heartbeat,max_heartbeat_gap=max_gap})..'\n')
