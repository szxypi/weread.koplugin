-- Bounded subprocess results travel only through a pipe. No credential files,
-- log output, blocking EOF reads, or network requests on the UI event loop.
local Worker = {}
Worker.__index = Worker
local LIMIT = 65536

local function runner()
    local util = require("ffi/util")
    local ffi = require("ffi")
    return {
        run = function(callback)
            return util.runInSubProcess(function(_pid, fd) callback(fd) end, true)
        end,
        write = function(fd, bytes)
            local offset = 0
            while offset < #bytes do
                local n = tonumber(ffi.C.write(fd, bytes:sub(offset + 1), #bytes - offset))
                if n <= 0 then break end
                offset = offset + n
            end
            ffi.C.close(fd)
        end,
        read = function(fd)
            local size = util.getNonBlockingReadSize(fd)
            if size == nil then return nil end
            size = math.min(size, LIMIT + 1)
            if size == 0 then return "" end
            local buffer = ffi.new("char[?]", size)
            local n = tonumber(ffi.C.read(fd, buffer, size))
            if n < 0 then return nil end
            return ffi.string(buffer, n)
        end,
        close = function(fd) ffi.C.close(fd) end,
        done = util.isSubProcessDone,
        terminate = function(pid)
            util.terminateSubProcess(pid)
            -- Immediate cancellation may precede the child's setpgid().
            if not util.isSubProcessDone(pid) then ffi.C.kill(pid, 9) end
        end,
    }
end

function Worker:new(options)
    local limit = options.max_bytes or LIMIT
    assert(type(limit) == "number" and limit >= LIMIT and limit <= 8 * 1024 * 1024 and limit % 1 == 0,
        "invalid memory worker capacity")
    return setmetatable({ scheduler = assert(options.scheduler), codec = assert(options.codec),
        runner = options.runner or runner(), now = options.now or os.time, limit = limit }, self)
end

function Worker:_collect(job)
    if self.runner.done(job.pid) then return end
    self.scheduler:scheduleIn(0.2, function() self:_collect(job) end)
end

function Worker:cancel()
    local job = self.job
    if not job then return end
    self.job = nil
    self.scheduler:unschedule(job.poll)
    self.runner.terminate(job.pid)
    self.runner.close(job.fd)
    job.chunks = nil
    self:_collect(job)
end

function Worker:start(task, callback)
    self:cancel()
    local ok, pid, fd = pcall(self.runner.run, function(output)
        local success, value = pcall(task)
        local encoded, bytes = pcall(self.codec.json_encode, self.codec,
            success and value or { error = "worker_failed" })
        if not encoded or type(bytes) ~= "string" or #bytes > self.limit then bytes = '{"error":"worker_failed"}' end
        self.runner.write(output, bytes)
    end)
    if not ok or type(pid) ~= "number" or type(fd) ~= "number" then return false end
    local job = { pid = pid, fd = fd, chunks = {}, size = 0, started = self.now() }
    self.job = job
    job.poll = function()
        if self.job ~= job then return end
        local chunk = self.runner.read(job.fd)
        if chunk then
            job.size = job.size + #chunk
            if job.size <= self.limit then job.chunks[#job.chunks + 1] = chunk end
        end
        local done = self.runner.done(job.pid)
        if not chunk or job.size > self.limit or self.now() - job.started > 75 then
            self:cancel()
            callback(nil)
        elseif done and #chunk == 0 then
            self.runner.close(job.fd)
            self.job = nil
            local parsed, value = pcall(self.codec.json_decode, self.codec, table.concat(job.chunks))
            job.chunks = nil
            callback(parsed and type(value) == "table" and value or nil)
        else
            self.scheduler:scheduleIn(0.2, job.poll)
        end
    end
    self.scheduler:scheduleIn(0.2, job.poll)
    return true
end

return Worker
