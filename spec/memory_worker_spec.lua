package.path = "./?.lua;./?/init.lua;" .. package.path
local Worker = require("weread.lib.memory_worker")
local checks = 0
local function expect(value, label) checks = checks + 1 assert(value, label) end
local function fixture(max_bytes, timeout, read_size, fast_start)
    local queue, pending, bytes, completed, terminated, closed, now = {}, nil, "", false, false, false, 0
    local delays={}
    local scheduler = {
        scheduleIn = function(_self, delay, fn)
            expect(delay >= 0.02, "cooperative scheduling")
            delays[#delays+1]=delay;queue[#queue + 1] = fn
        end,
        unschedule = function(_self, fn) for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end end,
    }
    local codec = { json_encode = function(_self, value) return value end, json_decode = function(_self, raw)
        if raw == "bad" then error("private-body") end
        return { private = raw }
    end }
    local runner = {
        run = function(fn) pending = fn return 42, 43 end,
        write = function(_fd, raw, keep_open) bytes = bytes .. raw; if not keep_open then completed = true end; return true end,
        read = function() local size=read_size or 4096;local chunk = bytes:sub(1, size) bytes = bytes:sub(size+1) return chunk end,
        done = function() return completed end,
        close = function() closed = true;completed = true end,
        terminate = function() terminated, completed = true, true end,
    }
    local worker = Worker:new{ scheduler = scheduler, codec = codec, runner = runner, now = function() return now end,
        max_bytes = max_bytes, timeout = timeout, fast_start = fast_start }
    return { worker = worker, run = function() pending(43) end,
        tick = function() local fn = table.remove(queue, 1) if fn then fn() end end,
        idle = function() while #queue > 0 do table.remove(queue, 1)() end end,
        time = function(value) now = value end,
        state = function() return terminated, closed end, runner = runner,delays=delays,
        inject = function(value) bytes=bytes..value;completed=true end }
end
local f, got = fixture(), nil
expect(f.worker:start(function() return string.rep("x", 20000) end, function(value) got = value end), "worker starts")
f.tick()
expect(got == nil, "UI poll does not wait for network completion")
f.run(); f.idle()
expect(got and #got.private == 20000, "large pipe payload drained without waiting for EOF")
local _, closed = f.state()
expect(closed and not f.worker.job, "completed descriptor closed and job released")
expect(f.delays[1]==0.2,"default poll delayed unnecessary wakeups")
local fast=fixture(nil,nil,nil,true)
expect(fast.worker:start(function() return "quick" end,function() end),"interactive worker did not start")
fast.tick()
expect(fast.delays[1]==0.02 and fast.delays[2]==0.2,"interactive worker did not check early then return to idle polling")
fast.worker:cancel()
f = fixture(); got = nil
f.worker:start(function() return "private-value" end, function(value) got = value end)
f.worker:cancel(); f.idle()
local terminated
terminated, closed = f.state()
expect(terminated and closed and got == nil, "cancel terminates and closes without applying private outcome")
f = fixture(); got = false
f.worker:start(function() return "never" end, function(value) got = value or "failed" end)
f.time(76); f.tick()
terminated, closed = f.state()
expect(got == "failed" and terminated and closed, "deadline abandons/reaps worker")
f = fixture(nil, 1800); got = nil
f.worker:start(function() return "later" end, function(value) got = value or "failed" end)
f.time(76); f.tick(); terminated = f.state()
expect(not terminated and got == nil and f.worker.job ~= nil, "configured long upload deadline was ignored")
f.time(1801); f.tick(); terminated, closed = f.state()
expect(got == "failed" and terminated and closed, "configured upload deadline did not terminate worker")
for _, timeout in ipairs({-1, 0, 3601, 1.5}) do
    expect(not pcall(fixture, nil, timeout), "invalid worker timeout was accepted")
end
f = fixture(); got = false
f.worker:start(function() return "bad" end, function(value) got = value or "failed" end)
f.run(); f.idle()
expect(got == "failed", "decoder exception is redacted")
f = fixture(131072); got = nil
f.worker:start(function() return string.rep("x", 100000) end, function(value) got = value end)
f.run(); f.idle()
expect(got and #got.private == 100000, "configured shelf capacity accepts data above the authorization limit")
f = fixture(); f.runner.run = function() return false, "private-error" end
expect(not f.worker:start(function() end, function() error("must not callback") end), "fork failure returned without diagnostic data")
f = fixture(nil,nil,1);got=nil
local updates={}
f.worker:start(function(report)
    for _,value in ipairs({0,10,10,2,-1,1.5,101,90,100}) do report(value) end
    return 'finished'
end,function(value) got=value end,function(value) updates[#updates+1]=value end)
f.run();f.idle()
expect(got and got.private=='finished' and table.concat(updates,',')=='0,10,90,100',
    'fragmented progress stream or normal result was lost')
for _,malformed in ipairs({'p01\nrvalue','p101\nrvalue','p1\np1\nrvalue','p12','bad','p12345'}) do
    f=fixture(nil,nil,2);got=false
    f.worker:start(function() end,function(value) got=value or 'failed' end,function() end)
    f.inject(malformed);f.idle()
    expect(got=='failed','malformed progress stream was accepted')
end
f=fixture(nil,nil,2);got=nil
f.worker:start(function(report) report(10);return 'finished' end,function(value) got=value end,function() f.worker:cancel() end)
f.run();f.idle();terminated,closed=f.state()
expect(terminated and closed and got==nil,'progress callback cancellation applied an old result')
f=fixture(nil,nil,2);got=nil
f.worker:start(function(report) report(10);return 'finished' end,function(value) got=value end,function() error('private') end)
f.run();f.idle();expect(got and got.private=='finished','progress callback failure stopped the result')
f=fixture(131072,nil,4096);got=nil
f.worker:start(function(report) report(1);return string.rep('x',100000) end,function(value) got=value end,function() end)
f.run();f.idle();expect(got and #got.private==100000,'progress stream truncated a large bounded result')
f=fixture(nil,nil,1);got=nil
local reads,original_read=0,f.runner.read
f.runner.read=function(...) reads=reads+1;return original_read(...) end
f.worker:start(function() return string.rep('x',100) end,function(value) got=value end)
f.run();f.tick()
expect(reads==4 and not got,'one UI tick must drain no more than four chunks')
expect(f.delays[#f.delays]==0.02,'active pipe did not use the bounded fast poll')
f.idle();expect(got and #got.private==100,'bounded bursts lost data')
f=fixture();got=nil
f.worker:start(function() return 'later' end,function(value) got=value end)
f.tick();expect(f.delays[#f.delays]==0.2,'idle worker did not retain the low-frequency poll')
f.run();f.idle();expect(got and got.private=='later','idle-to-active transition lost the result')
f=fixture(65536,nil,4096);got=nil
f.worker:start(function() return string.rep('x',65537) end,function(value) got=value end)
f.run();f.idle()
expect(got and got.private=='{"error":"worker_failed"}','oversized child result was not bounded')
f=fixture(65536,nil,4096);got=false
f.worker:start(function() end,function(value) got=value or 'failed' end)
f.inject(string.rep('x',65537));f.idle();terminated,closed=f.state()
expect(got=='failed' and terminated and closed,'oversized pipe data was not rejected')
f=fixture();got=false;local writes=0
f.runner.write=function(_fd,_raw,_keep_open) writes=writes+1;return false end
f.worker:start(function() return 'never sent' end,function(value) got=value or 'failed' end,function() end)
f.run();f.idle();_,closed=f.state()
expect(writes==1 and closed and got=='failed','failed result marker did not close without sending the body')
print("PASS: " .. checks .. " bounded memory worker checks")
