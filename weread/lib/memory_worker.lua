-- Bounded subprocess results travel only through a pipe. No credential files,
-- log output, blocking EOF reads, or network requests on the UI event loop.
local Worker = {}
Worker.__index = Worker
local LIMIT = 65536
local ACTIVE_POLL, IDLE_POLL, READS_PER_TICK = 0.02, 0.2, 4

local function runner()
    local util = require("ffi/util")
    local ffi = require("ffi")
    return {
        run = function(callback)
            return util.runInSubProcess(function(_pid, fd) callback(fd) end, true)
        end,
        write = function(fd, bytes, keep_open)
            local offset = 0
            -- Keep the string live while advancing a pointer into it. A short
            -- write must not copy the entire remaining payload on each retry.
            local pinned = { bytes }
            local data = ffi.cast('const char *', pinned[1])
            while offset < #bytes do
                local n = tonumber(ffi.C.write(fd, data + offset, #bytes - offset))
                if n > 0 then offset = offset + n
                elseif n >= 0 or ffi.errno() ~= ffi.C.EINTR then break end
            end
            if not keep_open then ffi.C.close(fd) end
            return offset == #pinned[1]
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
    local timeout = options.timeout or 75
    assert(type(limit) == "number" and limit >= LIMIT and limit <= 8 * 1024 * 1024 and limit % 1 == 0,
        "invalid memory worker capacity")
    assert(type(timeout) == "number" and timeout >= 1 and timeout <= 3600 and timeout % 1 == 0,
        "invalid memory worker timeout")
    return setmetatable({ scheduler = assert(options.scheduler), codec = assert(options.codec),
        runner = options.runner or runner(), now = options.now or os.time, limit = limit, timeout = timeout,
        first_poll = options.fast_start and ACTIVE_POLL or IDLE_POLL }, self)
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

-- Optional progress is a bounded stream of integer percentages on the same
-- anonymous pipe. At most 101 small updates can precede the normal result;
-- source text and credentials never enter progress frames.
function Worker:start(task, callback, on_progress)
    self:cancel()
    local streaming = type(on_progress) == 'function'
    local ok, pid, fd = pcall(self.runner.run, function(output)
        local last = -1
        local function report(value)
            if not streaming or type(value) ~= 'number' or value % 1 ~= 0
                or value < 0 or value > 100 or value <= last then return end
            last = value
            self.runner.write(output, 'p' .. tostring(value) .. '\n', true)
        end
        local success, value
        if streaming then success, value = pcall(task, report)
        else success, value = pcall(task) end
        local encoded, bytes = pcall(self.codec.json_encode, self.codec,
            success and value or { error = "worker_failed" })
        if not encoded or type(bytes) ~= "string" or #bytes > self.limit then bytes = '{"error":"worker_failed"}' end
        -- The marker can travel separately: the parent already accepts
        -- fragmented frames. Avoid copying an entire large result to prepend it.
        if streaming and not self.runner.write(output, 'r', true) then
            self.runner.close(output)
            return
        end
        self.runner.write(output, bytes)
    end)
    if not ok or type(pid) ~= "number" or type(fd) ~= "number" then return false end
    local job = { pid = pid, fd = fd, chunks = {}, size = 0, started = self.now(),
        streaming = streaming, prefix = '', last_progress = -1 }
    self.job = job
    job.poll = function()
        if self.job ~= job then return end
        local received = false
        for _ = 1, READS_PER_TICK do
            local chunk = self.runner.read(job.fd)
            local empty = chunk == ''
            if chunk and not empty then received = true end
            local valid = true
            if chunk and streaming and not job.result_started then
                job.prefix = job.prefix .. chunk
                while #job.prefix > 0 and not job.result_started do
                    if job.prefix:sub(1,1) == 'r' then
                        job.result_started = true
                        chunk = job.prefix:sub(2); job.prefix = ''
                    elseif job.prefix:sub(1,1) == 'p' then
                        local at = job.prefix:find('\n', 1, true)
                        if not at then
                            if #job.prefix > 4 then valid = false end
                            chunk = ''; break
                        end
                        local raw = job.prefix:sub(2,at-1)
                        local value = raw:match('^%d%d?%d?$') and tonumber(raw)
                        if not value or tostring(value) ~= raw or value > 100 or value <= job.last_progress then valid = false; break end
                        job.last_progress = value
                        job.prefix = job.prefix:sub(at+1)
                        pcall(on_progress,value)
                        if self.job ~= job then return end
                    else valid = false; break end
                end
                if not job.result_started then chunk = '' end
            end
            if chunk and (not streaming or job.result_started) then
                job.size = job.size + #chunk
                if job.size <= self.limit then job.chunks[#job.chunks + 1] = chunk end
            end
            local done = self.runner.done(job.pid)
            if not valid or not chunk or job.size > self.limit or self.now() - job.started > self.timeout then
                self:cancel()
                callback(nil)
                return
            elseif done and empty then
                self.runner.close(job.fd)
                self.job = nil
                local parsed, value = false, nil
                if not streaming or job.result_started then
                    parsed, value = pcall(self.codec.json_decode, self.codec, table.concat(job.chunks))
                end
                job.chunks = nil
                callback(parsed and type(value) == "table" and value or nil)
                return
            end
            if empty then break end
        end
        -- Drain active pipes promptly, but limit each UI tick's work. Idle
        -- workers keep the lower-frequency poll to avoid needless wakeups.
        self.scheduler:scheduleIn(received and ACTIVE_POLL or IDLE_POLL, job.poll)
    end
    self.scheduler:scheduleIn(self.first_poll, job.poll)
    return true
end

return Worker
