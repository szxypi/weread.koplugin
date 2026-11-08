-- Transactional local reading-time ledger. No credentials or network code.
-- Tuple watermarks and captured seconds commit together.
local Store = {}
Store.__index = Store
local MAX_ROWS = 50000

local function integer(value, minimum, maximum)
    local n = tonumber(value)
    return n and n == n and n % 1 == 0 and n >= minimum and n <= maximum and n or nil
end

local function query(db, sql, ...)
    local stmt = db:prepare(sql)
    local args = { ... }
    local ok, rows = pcall(function()
        if #args > 0 then stmt:bind(unpack(args)) end
        local result = {}
        while true do
            local row = stmt:step()
            if not row then break end
            result[#result + 1] = row
        end
        return result
    end)
    stmt:close()
    if not ok then error(rows) end
    return rows
end

function Store:new(data_dir)
    return setmetatable({ data_dir = assert(data_dir) }, self)
end

function Store:path(account)
    if type(account) ~= "string" or #account ~= 20 or not account:match("^[a-f0-9]+$") then return nil end
    return self.data_dir .. "/offline-time-" .. account .. ".db"
end

function Store:_access(account, change)
    local path = self:path(account)
    if not path then return nil, "account_unavailable" end
    local loaded, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not loaded then return nil, "storage_unavailable" end
    local opened, db = pcall(SQ3.open, path)
    if not opened or not db then return nil, "storage_error" end
    local transaction = false
    local ok, result = pcall(function()
        db:exec("PRAGMA busy_timeout=200; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        db:exec([[
            CREATE TABLE IF NOT EXISTS windows (
                id INTEGER PRIMARY KEY AUTOINCREMENT, book_id TEXT NOT NULL,
                stats_book INTEGER NOT NULL, start_time INTEGER NOT NULL,
                last_seen INTEGER NOT NULL, time_zone TEXT NOT NULL,
                book_version INTEGER NOT NULL DEFAULT 0, closed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS marks (
                window_id INTEGER NOT NULL, page TEXT NOT NULL, origin INTEGER NOT NULL,
                seen INTEGER NOT NULL, skip INTEGER NOT NULL,
                PRIMARY KEY(window_id,page,origin)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS aliases (
                window_id INTEGER NOT NULL, page TEXT NOT NULL, start_time INTEGER NOT NULL,
                origin INTEGER NOT NULL, PRIMARY KEY(window_id,page,start_time)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT, window_id INTEGER NOT NULL,
                start_time INTEGER NOT NULL, duration INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', attempt TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS segments_window ON segments(window_id);
            CREATE TABLE IF NOT EXISTS totals (name TEXT PRIMARY KEY, seconds INTEGER NOT NULL) WITHOUT ROWID;
        ]])
        db:exec("BEGIN IMMEDIATE")
        transaction = true
        local value = change(db)
        db:exec("COMMIT")
        transaction = false
        return value
    end)
    if transaction then pcall(db.exec, db, "ROLLBACK") end
    pcall(db.close, db)
    if ok then return result end
    return nil, tostring(result):find("ledger_full", 1, true) and "ledger_full" or "storage_error"
end

local function prune(db)
    db:exec("DELETE FROM marks WHERE window_id IN (SELECT id FROM windows WHERE closed=1);")
    db:exec("DELETE FROM aliases WHERE window_id IN (SELECT id FROM windows WHERE closed=1);")
    db:exec("DELETE FROM windows WHERE closed=1 AND id NOT IN (SELECT window_id FROM segments);")
end

function Store:recover(account)
    return self:_access(account, function(db)
        db:exec("UPDATE segments SET state='unknown' WHERE state='in_flight';")
        db:exec("UPDATE windows SET closed=1 WHERE closed=0;")
        prune(db)
        return true
    end)
end

function Store:begin(account, window)
    if type(window) ~= "table" or type(window.book_id) ~= "string" or window.book_id == "" or #window.book_id > 256
        or not integer(window.stats_book, 1, 2147483647) or not integer(window.start_time, 1, 4102444800)
        or type(window.time_zone) ~= "string" or not window.time_zone:match("^[+-]%d%d:%d%d$") then
        return nil, "invalid_window"
    end
    return self:_access(account, function(db)
        local floor = query(db, "SELECT seconds FROM totals WHERE name='capture_floor'")[1]
        if floor and tonumber(window.start_time) < tonumber(floor[1]) then return false end
        query(db, [[INSERT INTO windows(book_id,stats_book,start_time,last_seen,time_zone,book_version)
            VALUES(?,?,?,?,?,?)]], window.book_id, window.stats_book, window.start_time, window.start_time,
            window.time_zone, integer(window.book_version, 0, 2147483647) or 0)
        return tonumber(query(db, "SELECT last_insert_rowid()")[1][1])
    end)
end

function Store:collect(account, window_id, spans, now, close)
    if not integer(window_id, 1, 9007199254740991) or not integer(now, 1, 4102444800) then return nil, "invalid_window" end
    return self:_access(account, function(db)
        local window = query(db, "SELECT start_time,closed,last_seen FROM windows WHERE id=?", window_id)[1]
        if not window or tonumber(window[2]) ~= 0 then return { seconds = 0, rows = 0, closed = true } end
        if now < tonumber(window[3]) then error("invalid_capture_time") end
        local size = tonumber(query(db, "SELECT COUNT(*) FROM segments")[1][1])
        local seconds, count = 0, 0
        for _, span in ipairs(spans or {}) do
            local start = integer(span.start_time, 1, 4102444800)
            local duration = integer(span.duration, 1, 86400)
            local page = tostring(span.page or "")
            if start and duration and #page > 0 and #page <= 64 then
                local alias = query(db, "SELECT origin FROM aliases WHERE window_id=? AND page=? AND start_time=?",
                    window_id, page, start)[1]
                local origin = alias and tonumber(alias[1]) or integer(span.source_start, 1, start) or start
                query(db, "INSERT OR IGNORE INTO aliases VALUES(?,?,?,?)", window_id, page, start, origin)
                local mark = query(db, "SELECT seen,skip FROM marks WHERE window_id=? AND page=? AND origin=?",
                    window_id, page, origin)[1]
                local previous = mark and tonumber(mark[1]) or 0
                local skip = mark and tonumber(mark[2]) or math.max(0, tonumber(window[1]) - origin)
                local eligible = math.max(0, math.min(duration, now - start) - skip)
                local remaining = eligible - previous
                if remaining > 0 then
                    local at = start + skip + previous
                    while remaining > 0 do
                        if size + count >= MAX_ROWS then error("ledger_full") end
                        local part = math.min(60, remaining)
                        query(db, "INSERT INTO segments(window_id,start_time,duration) VALUES(?,?,?)", window_id, at, part)
                        seconds, count, at, remaining = seconds + part, count + 1, at + part, remaining - part
                    end
                    query(db, [[INSERT INTO marks VALUES(?,?,?,?,?) ON CONFLICT(window_id,page,origin)
                        DO UPDATE SET seen=excluded.seen]], window_id, page, origin, eligible, skip)
                end
            end
        end
        query(db, "UPDATE windows SET last_seen=MAX(last_seen,?),closed=? WHERE id=?", now, close and 1 or 0, window_id)
        query(db, [[INSERT INTO totals VALUES('capture_floor',?) ON CONFLICT(name)
            DO UPDATE SET seconds=MAX(seconds,excluded.seconds)]], now)
        if close then prune(db) end
        return { seconds = seconds, rows = count }
    end)
end

function Store:summary(account)
    return self:_access(account, function(db)
        local result = { pending = 0, in_flight = 0, unknown = 0, confirmed = 0, rows = 0 }
        for _, row in ipairs(query(db, "SELECT state,SUM(duration),COUNT(*) FROM segments GROUP BY state")) do
            result[row[1]], result.rows = tonumber(row[2]), result.rows + tonumber(row[3])
        end
        local confirmed = query(db, "SELECT seconds FROM totals WHERE name='confirmed'")[1]
        result.confirmed = confirmed and tonumber(confirmed[1]) or 0
        return result
    end)
end

-- Local queue transitions for the future transport adapter. An interrupted
-- dispatched request is uncertain; it must never be silently replayed.
function Store:pending(account, limit)
    limit = integer(limit, 1, 100) or 100
    return self:_access(account, function(db)
        local result = {}
        for _, row in ipairs(query(db, [[SELECT s.id,w.book_id,s.start_time,s.duration,w.time_zone,w.book_version
            FROM segments s JOIN windows w ON w.id=s.window_id WHERE s.state='pending' ORDER BY s.id LIMIT ?]], limit)) do
            result[#result + 1] = { id = tonumber(row[1]), book_id = row[2], start_time = tonumber(row[3]),
                duration = tonumber(row[4]), time_zone = row[5], book_version = tonumber(row[6]) }
        end
        return result
    end)
end

function Store:claim(account, rows, attempt)
    if type(rows) ~= "table" or #rows == 0 or #rows > 100 or type(attempt) ~= "string" or attempt == "" or #attempt > 128 then return false end
    return self:_access(account, function(db)
        local seen = {}
        for _, item in ipairs(rows) do
            local id = integer(item.id, 1, 9007199254740991)
            if not id or seen[id] then return false end
            seen[id] = true
            local row = query(db, [[SELECT s.state,s.duration,s.start_time,w.book_id,w.time_zone,w.book_version
                FROM segments s JOIN windows w ON w.id=s.window_id WHERE s.id=?]], item.id)[1]
            if not row or row[1] ~= "pending" or tonumber(row[2]) ~= item.duration or tonumber(row[3]) ~= item.start_time
                or row[4] ~= item.book_id or row[5] ~= item.time_zone or tonumber(row[6]) ~= item.book_version then return false end
        end
        for _, item in ipairs(rows) do query(db, "UPDATE segments SET state='in_flight',attempt=? WHERE id=?", attempt, item.id) end
        return true
    end)
end

function Store:finish(account, rows, attempt, state)
    if type(rows) ~= "table" or #rows > 100 or type(attempt) ~= "string" or attempt == "" or #attempt > 128 then return nil, "invalid_attempt" end
    if state ~= "confirmed" and state ~= "pending" and state ~= "unknown" then return nil, "invalid_state" end
    return self:_access(account, function(db)
        local seconds = 0
        for _, item in ipairs(rows or {}) do
            local row = query(db, "SELECT duration FROM segments WHERE id=? AND state='in_flight' AND attempt=?", item.id, attempt)[1]
            if row then
                seconds = seconds + tonumber(row[1])
                if state == "confirmed" then query(db, "DELETE FROM segments WHERE id=?", item.id)
                else query(db, "UPDATE segments SET state=?,attempt='' WHERE id=?", state, item.id) end
            end
        end
        if state == "confirmed" then
            query(db, [[INSERT INTO totals VALUES('confirmed',?) ON CONFLICT(name)
                DO UPDATE SET seconds=seconds+excluded.seconds]], seconds)
            prune(db)
        end
        return seconds
    end)
end

return Store
