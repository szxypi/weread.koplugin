-- Conservative local coverage of outgoing Web reading-time requests.
-- Commit before HTTP: a timeout or killed worker may still have been accepted.
-- Ranges describe [ct-rt, ct); actual server attribution remains unverified.
local Coverage = {}
Coverage.__index = Coverage
local MAX_ROWS = 50000

local function integer(value, low, high)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= low and value <= high
end

local function scope(account)
    if account == nil then return "" end -- Unidentified sends may overlap any account.
    if type(account) == "string" and #account == 20 and account:match("^[0-9a-f]+$") then return account end
end

local function query(db, sql, ...)
    local stmt = db:prepare(sql)
    local args = { ... }
    local ok, rows = pcall(function()
        if #args > 0 then stmt:bind(unpack(args)) end
        local result = {}
        while true do
            local row = stmt:step()
            if not row then return result end
            result[#result + 1] = row
        end
    end)
    stmt:close()
    if not ok then error(rows) end
    return rows
end

function Coverage:new(data_dir, now)
    return setmetatable({ path = assert(data_dir) .. "/reading-time-coverage.db", now = now or os.time }, self)
end

function Coverage:_access(callback)
    local loaded, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not loaded then return nil, "coverage_storage_unavailable" end
    local opened, db = pcall(SQ3.open, self.path)
    if not opened or not db then return nil, "coverage_storage_error" end
    local transaction = false
    local ok, result = pcall(function()
        db:exec("PRAGMA busy_timeout=200; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        db:exec([[CREATE TABLE IF NOT EXISTS coverage (
            scope TEXT NOT NULL, start_time INTEGER NOT NULL, end_time INTEGER NOT NULL,
            PRIMARY KEY(scope,start_time)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS coverage_end ON coverage(scope,end_time);
            CREATE TABLE IF NOT EXISTS coverage_meta (name TEXT PRIMARY KEY,value INTEGER NOT NULL) WITHOUT ROWID;]])
        db:exec("BEGIN IMMEDIATE")
        transaction = true
        local now = self.now()
        if not integer(now, 1, 4102444800) then error("invalid_clock") end
        query(db, "INSERT OR IGNORE INTO coverage_meta VALUES('tracked_since',?)", now)
        local since = tonumber(query(db, "SELECT value FROM coverage_meta WHERE name='tracked_since'")[1][1])
        if not integer(since, 1, 4102444800) then error("invalid_clock") end
        local value = callback(db, since)
        db:exec("COMMIT")
        transaction = false
        return value
    end)
    if transaction then pcall(db.exec, db, "ROLLBACK") end
    pcall(db.close, db)
    if ok then return result end
    return nil, tostring(result):find("coverage_full", 1, true) and "coverage_full" or "coverage_storage_error"
end

function Coverage:initialize()
    return self:_access(function(_db, since) return since end)
end

function Coverage:reserve(account, endpoint, seconds)
    if seconds == 0 then return true end -- Position-only and enter requests carry no time.
    local key = scope(account)
    if key == nil or not integer(endpoint, 1, 4102444800) or not integer(seconds, 1, 86400)
        or endpoint - seconds < 1 then return nil, "invalid_coverage" end
    return self:_access(function(db)
        local start, finish = endpoint - seconds, endpoint
        local overlapping = query(db, [[SELECT start_time,end_time FROM coverage
            WHERE scope=? AND start_time<=? AND end_time>=?]], key, finish, start)
        for _, row in ipairs(overlapping) do
            start, finish = math.min(start, tonumber(row[1])), math.max(finish, tonumber(row[2]))
        end
        -- Existing ranges for this scope are disjoint, so one merge pass suffices.
        if #overlapping == 0 and tonumber(query(db, "SELECT COUNT(*) FROM coverage")[1][1]) >= MAX_ROWS then
            error("coverage_full")
        end
        query(db, "DELETE FROM coverage WHERE scope=? AND start_time<=? AND end_time>=?", key, finish, start)
        query(db, "INSERT INTO coverage VALUES(?,?,?)", key, start, finish)
        return true
    end)
end

-- Planning only. No network or queue mutation. Unrecorded time before tracking
-- began is unknown, not demonstrably uncovered. Keep both categories separate.
function Coverage.subtract(start, duration, since, ranges)
    if not integer(start, 1, 4102444800) or not integer(duration, 1, 86400)
        or start + duration > 4102444800 or type(ranges) ~= "table"
        or not integer(since, 1, 4102444800) then return nil end
    local finish = start + duration
    local at = start
    local result = { parts = {}, eligible = 0, covered = 0, unverified = 0 }
    local sorted = {}
    for _, range in ipairs(ranges) do
        if not integer(range[1], 1, 4102444800) or not integer(range[2], range[1] + 1, 4102444800) then return nil end
        sorted[#sorted + 1] = { range[1], range[2] }
    end
    table.sort(sorted, function(a, b) return a[1] < b[1] end)
    local function append(last)
        if last <= at then return end
        local unknown = math.max(0, math.min(last, since) - at)
        result.unverified = result.unverified + unknown
        local available = last - at - unknown
        if available > 0 then
            result.parts[#result.parts + 1] = { start_time = at + unknown, duration = available }
            result.eligible = result.eligible + available
        end
        at = last
    end
    for _, range in ipairs(sorted) do
        if range[1] < finish and range[2] > at then
            append(math.min(range[1], finish))
            local last = math.min(range[2], finish)
            result.covered = result.covered + last - at
            at = last
        end
    end
    append(finish)
    return result
end

function Coverage:preview(account, rows)
    local key = scope(account)
    if key == nil or key == "" or type(rows) ~= "table" or #rows > 100 then return nil, "invalid_coverage" end
    local ordered, seen = {}, {}
    for _, row in ipairs(rows) do
        if type(row) ~= "table" or not integer(row.id, 1, 9007199254740991) or seen[row.id]
            or not integer(row.start_time, 1, 4102444800) or not integer(row.duration, 1, 60)
            or row.start_time + row.duration > 4102444800 then return nil, "invalid_coverage" end
        seen[row.id] = true
        ordered[#ordered + 1] = row
    end
    table.sort(ordered, function(a, b) return a.start_time < b.start_time end)
    local previous_end = 0
    for _, row in ipairs(ordered) do
        if row.start_time < previous_end then return nil, "invalid_coverage" end
        previous_end = row.start_time + row.duration
    end
    return self:_access(function(db, since)
        local result = { eligible = 0, covered = 0, unverified = 0, parts = {} }
        for _, row in ipairs(ordered) do
            local ranges = query(db, [[SELECT start_time,end_time FROM coverage WHERE (scope=? OR scope='')
                AND start_time<? AND end_time>?]], key, row.start_time + row.duration, row.start_time)
            for _, range in ipairs(ranges) do range[1], range[2] = tonumber(range[1]), tonumber(range[2]) end
            local split = assert(Coverage.subtract(row.start_time, row.duration, since, ranges))
            for _, part in ipairs(split.parts) do
                part.row_id = row.id
                result.parts[#result.parts + 1] = part
            end
            for _, name in ipairs({ "eligible", "covered", "unverified" }) do result[name] = result[name] + split[name] end
        end
        return result
    end)
end

return Coverage
