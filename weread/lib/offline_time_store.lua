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
            CREATE INDEX IF NOT EXISTS segments_time ON segments(start_time);
            CREATE INDEX IF NOT EXISTS segments_state_id ON segments(state,id);
            CREATE TABLE IF NOT EXISTS transfer_receipts(attempt TEXT PRIMARY KEY,rows_hash TEXT NOT NULL,seconds INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS totals (name TEXT PRIMARY KEY, seconds INTEGER NOT NULL) WITHOUT ROWID;
        ]])
        -- Old rows keep their original values and explicitly unverified origin.
        pcall(db.exec, db, "ALTER TABLE windows ADD COLUMN file_id TEXT NOT NULL DEFAULT ''")
        pcall(db.exec, db, "ALTER TABLE windows ADD COLUMN version_source TEXT NOT NULL DEFAULT 'legacy_unverified'")
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

-- The indexed overlap checks rely on these bounds, including other books and
-- unverified sources. Corrupt/orphan rows must never be silently overlooked.
local function check_segments(db)
    assert(#query(db,[[SELECT s.id FROM segments s LEFT JOIN windows w ON w.id=s.window_id
        WHERE w.id IS NULL OR typeof(s.id)<>'integer' OR s.id<1 OR s.id>9007199254740991
        OR typeof(s.start_time)<>'integer' OR s.start_time<1
        OR typeof(s.duration)<>'integer' OR s.duration<1 OR s.duration>60
        OR s.start_time+s.duration>4102444800
        OR s.state NOT IN ('pending','in_flight','unknown','covered') LIMIT 1]])==0,'corrupt')
    assert(tonumber(query(db,'SELECT COUNT(*) FROM segments')[1][1])<=MAX_ROWS,'ledger_full')
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
    local version = integer(window.book_version, 0, 2147483647) or 0
    local file_id, origin = window.file_id or "", window.version_source or "legacy_unverified"
    local valid_id = type(file_id) == "string" and #file_id == 64 and file_id:match("^[0-9a-f]+$")
    if not ({ legacy_unverified = true, unavailable = true, epub_unknown = true, epub_snapshot = true })[origin]
        or (file_id ~= "" and not valid_id) or (origin == "epub_snapshot" and (version == 0 or not valid_id))
        or (origin == "epub_unknown" and (version ~= 0 or not valid_id))
        or (origin == "unavailable" and (version ~= 0 or file_id ~= "")) then return nil, "invalid_window" end
    return self:_access(account, function(db)
        local floor = query(db, "SELECT seconds FROM totals WHERE name='capture_floor'")[1]
        if floor and tonumber(window.start_time) < tonumber(floor[1]) then return false end
        query(db, [[INSERT INTO windows(book_id,stats_book,start_time,last_seen,time_zone,book_version,file_id,version_source)
            VALUES(?,?,?,?,?,?,?,?)]], window.book_id, window.stats_book, window.start_time, window.start_time,
            window.time_zone, version, file_id, origin)
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
        check_segments(db)
        local result = { pending = 0, in_flight = 0, unknown = 0, covered = 0, confirmed = 0, rows = 0 }
        for _, row in ipairs(query(db, "SELECT state,SUM(duration),COUNT(*) FROM segments GROUP BY state")) do
            result[row[1]], result.rows = tonumber(row[2]), result.rows + tonumber(row[3])
        end
        local confirmed = query(db, "SELECT seconds FROM totals WHERE name='confirmed'")[1]
        result.confirmed = confirmed and tonumber(confirmed[1]) or 0
        return result
    end)
end

local CATEGORIES={pending="s.state='pending'",review="s.state IN ('in_flight','unknown')",covered="s.state='covered'",all="1=1"}
function Store:review_page(account,category,after_id,upper_id,limit)
    local C=require('weread.lib.readtime_transfer_contract')
    after_id,limit=after_id or 0,limit or 20
    if not CATEGORIES[category] or not C.integer(after_id,0,2^53-1) or not C.integer(limit,1,100)
        or upper_id~=nil and not C.integer(upper_id,after_id,2^53-1) then return nil,'invalid_page' end
    return self:_access(account,function(db)
        check_segments(db)
        local ceiling=upper_id or tonumber(query(db,'SELECT COALESCE(MAX(id),0) FROM segments')[1][1])
        local found=query(db,[[SELECT s.id,w.book_id,s.start_time,s.duration,w.time_zone,w.book_version,w.file_id,w.version_source,s.state,
            EXISTS(SELECT 1 FROM segments other WHERE other.id<>s.id AND other.state IN ('pending','in_flight','unknown')
                AND other.start_time>=s.start_time-59 AND other.start_time<s.start_time+s.duration
                AND other.start_time+other.duration>s.start_time)
            FROM segments s JOIN windows w ON w.id=s.window_id WHERE ]]..CATEGORIES[category]..[[
            AND s.id>? AND s.id<=? ORDER BY s.id LIMIT ?]],after_id,ceiling,limit+1)
        local page={rows={},upper_id=ceiling,after_id=after_id,has_more=#found>limit}
        for index=1,math.min(limit,#found) do
            local row=found[index]
            local source={id=tonumber(row[1]),book_id=row[2],start_time=tonumber(row[3]),duration=tonumber(row[4]),time_zone=row[5],
                book_version=tonumber(row[6]),file_id=row[7],version_source=row[8]}
            assert(C.row(source),'corrupt')
            local blocked={}
            if tonumber(row[10])==1 then
                local stamps=query(db,[[WITH RECURSIVE seconds(stamp,n) AS
                    (SELECT CAST(? AS INTEGER),1 UNION ALL SELECT stamp+1,n+1 FROM seconds WHERE n<60 AND stamp+1<CAST(? AS INTEGER))
                    SELECT stamp FROM seconds WHERE EXISTS(SELECT 1 FROM segments other
                        WHERE other.id<>? AND other.state IN ('pending','in_flight','unknown')
                        AND other.start_time>=? AND other.start_time<=stamp AND other.start_time+other.duration>stamp)
                    ORDER BY stamp]],source.start_time,source.start_time+source.duration,source.id,source.start_time-59)
                for _i,item in ipairs(stamps) do
                    local stamp=tonumber(item[1]);local last=blocked[#blocked]
                    if last and last[2]==stamp then last[2]=stamp+1 else blocked[#blocked+1]={stamp,stamp+1} end
                end
            end
            page.rows[#page.rows+1]={source=source,state=row[9],conflict=#blocked>0,blocked=blocked}
        end
        page.last_id=#page.rows>0 and page.rows[#page.rows].source.id or after_id
        return page
    end)
end

-- Local queue transitions for the future transport adapter. An interrupted
-- dispatched request is uncertain; it must never be silently replayed.
function Store:pending(account, limit, after_id)
    limit = integer(limit, 1, 100) or 100
    after_id=integer(after_id or 0,0,2^53-1) or 0
    return self:_access(account, function(db)
        local result = {}
        for _, row in ipairs(query(db, [[SELECT s.id,w.book_id,s.start_time,s.duration,w.time_zone,w.book_version,w.file_id,w.version_source
            FROM segments s JOIN windows w ON w.id=s.window_id WHERE s.state='pending' AND s.id>? ORDER BY s.id LIMIT ?]],after_id,limit)) do
            result[#result + 1] = { id = tonumber(row[1]), book_id = row[2], start_time = tonumber(row[3]),
                duration = tonumber(row[4]), time_zone = row[5], book_version = tonumber(row[6]),
                file_id = row[7], version_source = row[8] }
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
            local row = query(db, [[SELECT s.state,s.duration,s.start_time,w.book_id,w.time_zone,w.book_version,w.file_id,w.version_source
                FROM segments s JOIN windows w ON w.id=s.window_id WHERE s.id=?]], item.id)[1]
            if not row or row[1] ~= "pending" or tonumber(row[2]) ~= item.duration or tonumber(row[3]) ~= item.start_time
                or row[4] ~= item.book_id or row[5] ~= item.time_zone or tonumber(row[6]) ~= item.book_version
                or row[7] ~= item.file_id or row[8] ~= item.version_source then return false end
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

local function source_row(db,id)
    return query(db,[[SELECT s.state,s.attempt,s.start_time,s.duration,w.book_id,w.time_zone,w.book_version,w.file_id,w.version_source,w.id
        FROM segments s JOIN windows w ON s.window_id=w.id WHERE s.id=?]],id)[1]
end
local function same_row(found,row)
    return found and tonumber(found[3])==row.start_time and tonumber(found[4])==row.duration
        and found[5]==row.book_id and found[6]==row.time_zone and tonumber(found[7])==row.book_version
        and found[8]==row.file_id and found[9]==row.version_source
end
function Store:owns(account,rows,attempt)
    local C=require('weread.lib.readtime_transfer_contract')
    if not C.attempt(attempt) or not C.array(rows,1,100) then return false end
    return self:_access(account,function(db)
        local seen={}
        for _i,row in ipairs(rows) do
            if not C.row(row) or seen[row.id] then return false end
            seen[row.id]=true
            local found=source_row(db,row.id)
            if not same_row(found,row) or found[1]~='in_flight' or found[2]~=attempt then return false end
        end
        return true
    end)
end
-- Called only while the coverage writer owns its BEGIN IMMEDIATE transaction.
-- Known online ranges become a distinct retained category, never "confirmed".
function Store:claim_parts(account,rows,parts,attempt,covered)
    local C=require('weread.lib.readtime_transfer_contract')
    if not C.attempt(attempt) or not C.array(rows,1,100) or not C.array(parts,1,100) or type(covered)~='function' then return nil end
    return self:_access(account,function(db)
        check_segments(db)
        local originals,selected,seen={},{},{}
        for _i,row in ipairs(rows) do
            assert(C.row(row),'invalid_row')
            local found=source_row(db,row.id)
            if seen[row.id] or not same_row(found,row) or found[1]~='pending' then error('changed') end
            seen[row.id]=true;originals[row.id]={row=row,window=tonumber(found[10])};selected[row.id]={}
        end
        for _i,part in ipairs(parts) do
            assert(C.part(part),'invalid_parts')
            local item=originals[part.row_id];local row=item and item.row
            assert(row and C.integer(part.start_time,row.start_time,row.start_time+row.duration-1)
                and C.integer(part.duration,1,row.start_time+row.duration-part.start_time),'invalid_parts')
            for stamp=part.start_time,part.start_time+part.duration-1 do
                assert(not selected[row.id][stamp] and not covered(row.id,stamp),'overlap')
                selected[row.id][stamp]=true
            end
            -- Row durations are bounded to sixty seconds; a conflicting source
            -- in any book is ambiguous, even when it is outside this batch.
            assert(#query(db,[[SELECT id FROM segments WHERE start_time>=? AND start_time<? AND start_time+duration>?
                AND state IN ('pending','in_flight','unknown') AND id<>?]],
                part.start_time-59,part.start_time+part.duration,part.start_time,row.id)==0,'overlap')
        end
        local result={};local count=tonumber(query(db,'SELECT COUNT(*) FROM segments')[1][1])
        for _i,row in ipairs(rows) do
            query(db,'DELETE FROM segments WHERE id=?',row.id);count=count-1
            local first,state=row.start_time,nil
            local function insert(last)
                if not state or last<=first then return end
                assert(count<MAX_ROWS,'ledger_full');count=count+1
                local token=state=='in_flight' and attempt or ''
                query(db,'INSERT INTO segments(window_id,start_time,duration,state,attempt) VALUES(?,?,?,?,?)',originals[row.id].window,first,last-first,state,token)
                if state=='in_flight' then
                    local item={};for k,v in pairs(row) do item[k]=v end
                    item.id=tonumber(query(db,'SELECT last_insert_rowid()')[1][1]);item.start_time=first;item.duration=last-first
                    result[#result+1]=item;assert(#result<=100,'ledger_full')
                end
            end
            for stamp=row.start_time,row.start_time+row.duration-1 do
                local next_state=selected[row.id][stamp] and 'in_flight' or covered(row.id,stamp) and 'covered' or 'pending'
                if state~=next_state then insert(stamp);first,state=stamp,next_state end
            end
            insert(row.start_time+row.duration)
        end
        assert(#result>0,'empty');return result
    end)
end
-- A durable prepared coverage record proves the transport has not claimed it.
function Store:release_unsent(account,rows,attempt)
    local Contract=require('weread.lib.readtime_transfer_contract')
    if not Contract.attempt(attempt) or not Contract.array(rows,1,100) then return nil,'invalid_attempt' end
    local seen={}
    for _i,row in ipairs(rows) do
        if not Contract.row(row) or seen[row.id] then return nil,'invalid_attempt' end
        seen[row.id]=true
    end
    return self:_access(account,function(db)
        for _i,row in ipairs(rows) do
            local found=source_row(db,row.id)
            assert(same_row(found,row) and (found[2]==attempt and (found[1]=='in_flight' or found[1]=='unknown')
                or found[1]=='pending' and found[2]==''),'changed')
        end
        for _i,row in ipairs(rows) do query(db,"UPDATE segments SET state='pending',attempt='' WHERE id=?",row.id) end
        return true
    end)
end
function Store:settle_confirmed(account,rows,attempt)
    local Contract=require('weread.lib.readtime_transfer_contract')
    if not Contract.attempt(attempt) or not Contract.array(rows,1,100) then return nil,'invalid_attempt' end
    local seen={}
    for _i,row in ipairs(rows) do
        if not Contract.row(row) or seen[row.id] then return nil,'invalid_attempt' end
        seen[row.id]=true
    end
    local C=require('weread.lib.readtime_transfer_contract');local hash=C.digest(rows)
    return self:_access(account,function(db)
        local receipt=query(db,'SELECT rows_hash FROM transfer_receipts WHERE attempt=?',attempt)[1]
        if receipt then assert(receipt[1]==hash,'changed');return true end
        local seconds=0
        for _i,row in ipairs(rows) do
            local found=source_row(db,row.id)
            assert(same_row(found,row) and found[2]==attempt and (found[1]=='in_flight' or found[1]=='unknown'),'changed')
            seconds=seconds+row.duration
        end
        assert(tonumber(query(db,'SELECT COUNT(*) FROM transfer_receipts')[1][1])<MAX_ROWS,'ledger_full')
        for _i,row in ipairs(rows) do query(db,'DELETE FROM segments WHERE id=?',row.id) end
        query(db,[[INSERT INTO totals VALUES('confirmed',?) ON CONFLICT(name) DO UPDATE SET seconds=seconds+excluded.seconds]],seconds)
        query(db,'INSERT INTO transfer_receipts VALUES(?,?,?)',attempt,hash,seconds);prune(db);return true
    end)
end
function Store:mark_unknown(account,rows,attempt)
    local Contract=require('weread.lib.readtime_transfer_contract')
    if not Contract.attempt(attempt) or not Contract.array(rows,1,100) then return nil,'invalid_attempt' end
    local seen={}
    for _i,row in ipairs(rows) do
        if not Contract.row(row) or seen[row.id] then return nil,'invalid_attempt' end
        seen[row.id]=true
    end
    return self:_access(account,function(db)
        for _i,row in ipairs(rows) do
            local found=source_row(db,row.id)
            assert(same_row(found,row) and found[2]==attempt and (found[1]=='in_flight' or found[1]=='unknown'),'changed')
        end
        for _i,row in ipairs(rows) do query(db,"UPDATE segments SET state='unknown' WHERE id=?",row.id) end
        return true
    end)
end

return Store
