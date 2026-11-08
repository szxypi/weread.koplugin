package.path = "./?.lua;./?/init.lua;" .. package.path
local Data = require("weread.lib.profile")
local Stats = require("weread.lib.read_stats")
local checks = 0
local function expect(value, message) checks = checks + 1 assert(value, message) end
local function time(y, m, d) return Stats.cst_time{ year = y, month = m, day = d } end
expect(time(1970, 1, 1) == -28800, "Beijing epoch conversion failed")
expect(time(2024, 3, 1) - time(2024, 2, 1) == 29 * 86400, "leap February lost")
expect(Stats.shift_period("monthly", time(2024, 12, 1), 1) == time(2025, 1, 1), "December navigation failed")
expect(Stats.period_start("weekly", time(2024, 3, 10) + 12 * 3600) == time(2024, 3, 4), "DST/week boundary drift")
expect(Stats.period_start("monthly", time(2024, 11, 15)) == time(2024, 11, 1), "historical offset drift")
expect(Stats.cst_fmt("%Y-%m-%d", Stats.period_start("monthly", time(2010, 7, 15))) == "2010-07-01",
    "historical date-line/device timezone offset moved the calendar by a day")
expect(Data.day(time(2025, 1, 2) - 1) == time(2025, 1, 1), "Beijing midnight crossed early")
for _, value in ipairs({ 0, -1, 1441, 1.5, math.huge, "bad" }) do expect(not Data.goal(value), "invalid goal accepted") end
expect(Data.goal("45") == 45 and Data.goal(1440) == 1440, "valid goal rejected")
local jan, dec, now = time(2025, 1, 1), time(2024, 12, 1), time(2025, 1, 2) + 12 * 3600
local function raw(base, values)
    local daily = {}
    for day, seconds in pairs(values) do daily[tostring(base + (day - 1) * 86400)] = seconds end
    return { baseTime = base, readTimes = daily }
end
local january = Data.month(raw(jan, { [1] = 1800, [2] = 900 }), jan)
local december = Data.month(raw(dec, { [31] = 300 }), dec)
local months = { [tostring(jan)] = january, [tostring(dec)] = december }
local count, lower = Data.streak(months, now)
expect(count == 3 and not lower, "cross-year streak truncated or invented")
local snapshot = { months = months, fetched_at = now }
local model = Data.build(snapshot, 30, now)
expect(model.has_data and model.today_seconds == 900 and model.month_seconds == 2700
    and model.month_read_days == 2 and model.streak == 3, "dashboard totals incorrect")
expect(#model.days == 31 and model.first_weekday == 3 and model.days[2].today and model.days[3].future,
    "monthly heatmap date alignment failed")
january.daily[tostring(time(2025, 1, 2))] = 0
expect(Data.streak(months, now) == 2, "unread today erased yesterday's streak")
months[tostring(dec)] = nil
count, lower = Data.streak(months, now)
expect(count == 1 and lower, "missing month treated as confirmed zero")
local empty = Data.build(nil, nil, now)
expect(not empty.has_data and empty.goal_minutes == 30 and not empty.days[1].known, "missing data rendered as known inactivity")
expect(#Data.build(nil, 30, time(2024, 2, 10)).days == 29, "heatmap lost leap day")
local requests = {}
local client = { get_read_stats = function(_self, mode, base)
    requests[#requests + 1] = base
    expect(mode == "monthly", "daily calendar requested aggregate buckets")
    return base == jan and raw(jan, { [1] = 1800, [2] = 900 }) or raw(dec, { [31] = 300 })
end }
local ctx = { checkCancelled = function() end, emit = function() end }
local fetched = Data.fetch(client, ctx, now)
expect(#requests == 2 and Data.build(fetched, 30, now).streak == 3, "streak boundary did not fetch previous month")
requests = {}
client.get_read_stats = function(_self, _mode, base) requests[#requests + 1] = base return raw(base, {}) end
Data.fetch(client, ctx, now)
expect(#requests == 1, "no-activity dashboard fetched unnecessary months")
local bad_responses = { {}, { readTimes = { bad = 3 } }, raw(jan, { [1] = -1 }),
    { baseTime = dec, readTimes = {} }, raw(jan, { [32] = 60 }) }
for _, response in ipairs(bad_responses) do expect(not pcall(Data.month, response, jan), "malformed monthly data accepted") end
local milli = Data.month({ readTimes = { [tostring(jan * 1000)] = 60 } }, jan)
expect(milli.daily[tostring(jan)] == 60, "millisecond daily key not normalized")
local duplicate = Data.month({ readTimes = { [tostring(jan)] = 60, [tostring(jan * 1000)] = 60 } }, jan)
expect(duplicate.total == 60, "duplicate timestamp units doubled reading time")
expect(not pcall(Data.month, { readTimes = { [tostring(jan)] = 60, [tostring(jan * 1000)] = 120 } }, jan),
    "conflicting daily timestamps silently replaced activity")
local capped = 0
local old_cap = Data.MAX_STREAK_MONTHS
Data.MAX_STREAK_MONTHS = 2
client.get_read_stats = function(_self, _mode, base)
    capped = capped + 1
    local days = (Stats.shift_period("monthly", base, 1) - base) / 86400
    local values = {}
    for day = 1, days do values[day] = 60 end
    return raw(base, values)
end
local capped_model = Data.build(Data.fetch(client, ctx, now), 30, now)
expect(capped == 2 and capped_model.streak_lower_bound, "bounded streak presented as exact")
Data.MAX_STREAK_MONTHS = old_cap
expect(not pcall(Data.fetch, client, { checkCancelled = function() error("cancelled") end }, now), "cancelled fetch continued")
print("profile_data_spec: " .. checks .. " checks")
