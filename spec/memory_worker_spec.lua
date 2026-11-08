package.path = "./?.lua;./?/init.lua;" .. package.path
local Worker = require("weread.lib.memory_worker")
local checks = 0
local function expect(value, label) checks = checks + 1 assert(value, label) end
local function fixture()
    local queue, pending, bytes, completed, terminated, closed, now = {}, nil, "", false, false, false, 0
    local scheduler = {
        scheduleIn = function(_self, delay, fn) expect(delay >= 0.1, "cooperative scheduling") queue[#queue + 1] = fn end,
        unschedule = function(_self, fn) for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end end,
    }
    local codec = { json_encode = function(_self, value) return value end, json_decode = function(_self, raw)
        if raw == "bad" then error("private-body") end
        return { private = raw }
    end }
    local runner = {
        run = function(fn) pending = fn return 42, 43 end,
        write = function(_fd, raw) bytes, completed = raw, true end,
        read = function() local chunk = bytes:sub(1, 4096) bytes = bytes:sub(4097) return chunk end,
        done = function() return completed end,
        close = function() closed = true end,
        terminate = function() terminated, completed = true, true end,
    }
    local worker = Worker:new{ scheduler = scheduler, codec = codec, runner = runner, now = function() return now end }
    return { worker = worker, run = function() pending(43) end,
        tick = function() local fn = table.remove(queue, 1) if fn then fn() end end,
        idle = function() while #queue > 0 do table.remove(queue, 1)() end end,
        time = function(value) now = value end,
        state = function() return terminated, closed end, runner = runner }
end
local f, got = fixture(), nil
expect(f.worker:start(function() return string.rep("x", 20000) end, function(value) got = value end), "worker starts")
f.tick()
expect(got == nil, "UI poll does not wait for network completion")
f.run(); f.idle()
expect(got and #got.private == 20000, "large pipe payload drained without waiting for EOF")
local _, closed = f.state()
expect(closed and not f.worker.job, "completed descriptor closed and job released")
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
f = fixture(); got = false
f.worker:start(function() return "bad" end, function(value) got = value or "failed" end)
f.run(); f.idle()
expect(got == "failed", "decoder exception is redacted")
f = fixture(); f.runner.run = function() return false, "private-error" end
expect(not f.worker:start(function() end, function() error("must not callback") end), "fork failure returned without diagnostic data")
print("PASS: " .. checks .. " bounded memory worker checks")
