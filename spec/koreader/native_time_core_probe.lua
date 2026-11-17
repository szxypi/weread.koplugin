-- Synthetic HTTP only, actual KOReader JSON and SQLite. No account inputs.
require('setupkoenv')
local root=arg[1] or '/source';package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
assert(os.getenv('WEREAD_REAL_RUNTIME')=='1')
local Json=require('json');require('lua-ljsqlite3/init')
local mode=arg[2] or 'inline';assert(mode=='inline' or mode=='worker' or mode=='store' or mode=='source')
local function check()
    local file=mode=='store' and 'readtime_transfer_store_spec.lua' or mode=='source' and 'readtime_source_spec.lua' or 'readtime_transfer_task_spec.lua'
    dofile(root..'/spec/'..file)
end
if mode=='worker' then
    local Native=require('ffi/util');local socket=require('socket')
    local pid,fd=Native.runInSubProcess(function(_pid,output)
        local ok=pcall(check);Native.writeToFD(output,ok and 'PASS' or 'FAIL',true)
    end,true)
    assert(pid);local deadline=socket.gettime()+20
    while not Native.isSubProcessDone(pid) do
        if socket.gettime()>deadline then Native.terminateSubProcess(pid);error('native time worker timeout') end
        socket.sleep(.02)
    end
    assert(Native.readAllFromFD(fd)=='PASS')
else check() end
io.stdout:write('\nWEREAD_NATIVE_TIME_CORE='..Json.encode{result='PASS',synthetic_only=true,account_data_posts=0,mode=mode}..'\n')
