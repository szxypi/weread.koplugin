-- Account reading dashboard, using documented monthly /readdata/detail data.
-- Daily activity is measured in Beijing time, including across DST/year boundaries.
local Stats = require("weread.lib.read_stats")
local M = { TTL = 15 * 60, MAX_STREAK_MONTHS = 24, DEFAULT_GOAL = 30 }
local DAY = 86400

local function number(value)
    local n = tonumber(value)
    if n and n == n and n >= 0 and n < math.huge then return n end
end

function M.day(now)
    return math.floor((now + 8 * 3600) / DAY) * DAY - 8 * 3600
end

function M.goal(value)
    local minutes = number(value)
    return minutes and minutes >= 1 and minutes <= 1440 and minutes == math.floor(minutes) and minutes or nil
end

function M.month(raw, base)
    assert(type(raw) == "table" and type(raw.readTimes) == "table", "Missing daily reading statistics")
    local code = raw.errcode or raw.errCode
    assert(not code or tonumber(code) == 0, "Reading statistics rejected")
    local next_base = Stats.shift_period("monthly", base, 1)
    if raw.baseTime ~= nil then assert(tonumber(raw.baseTime) == base, "Reading statistics period mismatch") end
    local daily, total = {}, 0
    for key, value in pairs(raw.readTimes) do
        local stamp, seconds = number(key), number(value)
        assert(stamp and seconds, "Invalid daily reading statistics")
        if stamp >= 1e11 then stamp = stamp / 1000 end
        assert(stamp == M.day(stamp) and stamp >= base and stamp < next_base, "Daily statistics outside requested month")
        local previous = daily[tostring(stamp)]
        assert(previous == nil or previous == seconds, "Conflicting daily reading buckets")
        daily[tostring(stamp)] = seconds
        if previous == nil then total = total + seconds end
    end
    return { base = base, daily = daily, total = number(raw.totalReadTime) or total }
end

function M.streak(months, now)
    months = type(months) == "table" and months or {}
    local today, count = M.day(now), 0
    local cursor = today
    local current = months[tostring(Stats.period_start("monthly", cursor))]
    if type(current) ~= "table" or type(current.daily) ~= "table" then
        return 0, true, Stats.period_start("monthly", cursor)
    end
    if (current.daily[tostring(cursor)] or 0) <= 0 then cursor = cursor - DAY end
    -- Bound malformed/imported snapshots as well as network pagination.
    for _i = 1, 24 * 366 do
        local base = Stats.period_start("monthly", cursor)
        local month = months[tostring(base)]
        if type(month) ~= "table" or type(month.daily) ~= "table" then return count, true, base end
        if (month.daily[tostring(cursor)] or 0) <= 0 then return count, false end
        count, cursor = count + 1, cursor - DAY
    end
    return count, true
end

function M.fetch(client, context, now)
    now = now or os.time()
    local months, base = {}, Stats.period_start("monthly", now)
    for index = 1, M.MAX_STREAK_MONTHS do
        context.checkCancelled()
        context.emit { stage = "profile_stats", current = index }
        months[tostring(base)] = M.month(client:get_read_stats("monthly", base), base)
        local _, lower_bound, missing = M.streak(months, now)
        if not lower_bound or not missing then break end
        base = missing
    end
    context.checkCancelled()
    return { months = months, fetched_at = now }
end

function M.build(snapshot, goal, now)
    now = now or os.time()
    local base, today = Stats.period_start("monthly", now), M.day(now)
    local months = type(snapshot) == "table" and type(snapshot.months) == "table" and snapshot.months or {}
    local month = months[tostring(base)]
    if type(month) ~= "table" or type(month.daily) ~= "table" then month = nil end
    local days, read_days, first_weekday = {}, 0
    local next_base = Stats.shift_period("monthly", base, 1)
    for stamp = base, next_base - DAY, DAY do
        local seconds = month and month.daily[tostring(stamp)] or 0
        local weekday = tonumber(Stats.cst_fmt("%w", stamp))
        weekday = weekday == 0 and 7 or weekday
        first_weekday = first_weekday or weekday
        if stamp <= today and seconds > 0 then read_days = read_days + 1 end
        days[#days + 1] = { day = tonumber(Stats.cst_fmt("%d", stamp)), seconds = stamp <= today and seconds or 0,
            future = stamp > today, today = stamp == today, known = month ~= nil and stamp <= today }
    end
    local count, lower_bound = M.streak(months or {}, now)
    return { profile = true, has_data = month ~= nil, mode = "monthly", period_label = Stats.cst_fmt("%Y-%m", base),
        goal_minutes = M.goal(goal) or M.DEFAULT_GOAL, today_seconds = month and month.daily[tostring(today)] or 0,
        month_seconds = month and month.total or 0, month_read_days = read_days,
        streak = count, streak_lower_bound = lower_bound, days = days, first_weekday = first_weekday,
        fetched_at = type(snapshot) == "table" and number(snapshot.fetched_at) or nil }
end

return M
