require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local socket=require('socket')
local lfs=require('libs/libkoreader-lfs')
local banner=require('ui/widget/infomessage'):new{text='Synthetic worker cancellation'}
UI:show(banner);UI:forceRePaint()
local function descriptors()
    local count=0
    for name in lfs.dir('/proc/self/fd') do if name~='.' and name~='..' then count=count+1 end end
    return count
end
local function pump(predicate)
    local deadline=socket.gettime()+20
    while not predicate() do
        assert(socket.gettime()<deadline,'worker cancellation deadline')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(0.002)
    end
end
collectgarbage('collect');local before=descriptors()
local codec={json_encode=function(_,value) return value end,json_decode=function(_,value) return {body=value} end}
local Worker=require('weread.lib.memory_worker')
for _,streaming in ipairs({false,true}) do
    local callbacks,progress,cancelled=0,0,false
    local worker=Worker:new{scheduler=UI,codec=codec,max_bytes=8*1024*1024,timeout=60}
    assert(worker:start(function(report)
        if streaming then report(10) end
        return string.rep('x',8*1024*1024)
    end,function() callbacks=callbacks+1 end,streaming and function()
        progress=progress+1
        UI:scheduleIn(0.01,function() worker:cancel();cancelled=true end)
    end or nil))
    local pid=worker.job.pid
    if not streaming then UI:scheduleIn(0.3,function() worker:cancel();cancelled=true end) end
    pump(function() return cancelled and worker.runner.done(pid) end)
    assert(callbacks==0 and not worker.job,'cancelled worker delivered a result')
    if streaming then assert(progress==1,'progress frame was not delivered before cancellation') end
    local result
    assert(worker:start(function() return 'synthetic-ok' end,function(value) result=value or {} end))
    pump(function() return result~=nil end)
    assert(result.body=='synthetic-ok' and callbacks==0,'worker did not restart cleanly')
end
collectgarbage('collect');local after=descriptors()
assert(before==after,'worker cancellation leaked a descriptor')
UI:close(banner)
print('\nWEREAD_WORKER_CANCEL='..require('json').encode({result='PASS',modes=2,
    descriptors_before=before,descriptors_after=after,restarted=true})..'\n')
