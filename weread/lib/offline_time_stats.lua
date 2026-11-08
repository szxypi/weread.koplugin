-- Adapted from MiuRead's readtime_stats.lua (AGPL-3.0-only).
-- Copyright (C) 2026 MiuRead contributors. Source and changes: see NOTICE.
-- Read native statistics without changing its counters or database.
local M = {}

function M.available(stats)
    if not stats or not stats.id_curr_book or type(stats.page_stat) ~= "table" or type(stats.settings) ~= "table"
        or type(stats.isEnabledAndNotFrozen) ~= "function" then return false end
    local ok, enabled = pcall(stats.isEnabledAndNotFrozen, stats)
    return ok and enabled == true
end

function M.snapshot(stats, now, sources)
    local result = {}
    local minimum, maximum = tonumber(stats.settings.min_sec) or 5, tonumber(stats.settings.max_sec) or 120
    if minimum < 0 or maximum < minimum or maximum > 86400 then return result end
    local endpoint = math.min(now, tonumber(stats._reading_paused_ts) or now)
    for page, tuples in pairs(stats.page_stat) do
        for index, tuple in ipairs(tuples) do
            local start, duration = tonumber(tuple[1]), tonumber(tuple[2])
            if start and duration then
                local origin = sources[tuple] or start
                sources[tuple] = origin
                if duration == 0 and page == stats.curr_page and index == #tuples then
                    local elapsed = endpoint - start
                    duration = elapsed >= minimum and math.min(elapsed, maximum) or 0
                end
                if duration > 0 then result[#result + 1] = { page = page, start_time = start,
                    duration = duration, source_start = origin } end
            end
        end
    end
    return result
end

function M.persisted(stats, first, last, book_id)
    local SQ3 = require("lua-ljsqlite3/init")
    local path = require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
    local db = SQ3.open(path, "ro")
    local stmt
    local ok, result = pcall(function()
        db:exec("PRAGMA busy_timeout=100")
        stmt = db:prepare([[SELECT page,start_time,duration FROM page_stat_data
            WHERE id_book=? AND start_time>=? AND start_time<? AND duration>0 ORDER BY start_time]])
        stmt:bind(book_id or stats.id_curr_book, first - (tonumber(stats.settings.max_sec) or 120), last)
        local rows = {}
        while true do
            local row = stmt:step()
            if not row then break end
            rows[#rows + 1] = { page = tonumber(row[1]), start_time = tonumber(row[2]), duration = tonumber(row[3]) }
        end
        return rows
    end)
    if stmt then pcall(stmt.close, stmt) end
    pcall(db.close, db)
    if not ok then error("statistics_unavailable") end
    return result
end

return M
