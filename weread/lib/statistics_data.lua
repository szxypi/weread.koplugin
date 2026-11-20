-- Bounded statistics display projection. Native responses were verified by
-- scripts/verify_native_statistics.py before this Lua implementation.
local Stats = require("weread.lib.read_stats")
local M = {}
local function fail(reason) error("statistics/" .. reason, 0) end
local function numeric(value, maximum, minimum)
    return type(value) == "number" and value == value and value >= (minimum or 0) and value <= (maximum or 1e12)
end
local function text(value, limit)
    return type(value) == "string" and #value <= (limit or 4096) and not value:find("[%z%c]")
end
function M.mode(mode)
    for _, value in ipairs(Stats.MODES) do if mode == value then return true end end
    return false
end
function M.base(value)
    return numeric(value, 4102444800) and value % 1 == 0
end
local function array(value)
    if type(value) ~= "table" or #value > 100 then return false end
    for key in pairs(value) do if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end end
    return true
end

function M.project(raw, mode, base_time, now)
    if not M.mode(mode) or type(raw) ~= "table" or type(raw.readTimes) ~= "table" then fail("invalid") end
    if (raw.errcode ~= nil and tonumber(raw.errcode) ~= 0) or (raw.errCode ~= nil and tonumber(raw.errCode) ~= 0)
        or (raw.succ ~= nil and raw.succ ~= true and tonumber(raw.succ) ~= 1) then fail("rejected") end
    if not numeric(raw.totalReadTime) then fail("total_invalid") end
    if not numeric(raw.readDays, 1e7) or raw.readDays % 1 ~= 0 then fail("days_invalid") end
    if base_time ~= nil and not M.base(base_time) then fail("invalid_period") end
    local seed = base_time and base_time ~= 0 and base_time or now or os.time()
    local expected = mode == "overall" and 0 or Stats.period_start(mode, seed)
    local period_end = mode == "overall" and 4102444800 or Stats.shift_period(mode, expected, 1)
    if mode ~= "overall" and raw.readDays > (period_end - expected) / 86400 then fail("days_outside_period") end
    if mode ~= "overall" and (not M.base(raw.baseTime) or raw.baseTime ~= expected) then fail("period_mismatch") end
    local out = { baseTime = expected, readTimes = {}, totalReadTime = raw.totalReadTime }
    local count = 0
    for key, value in pairs(raw.readTimes) do
        count = count + 1
        if count > 512 or type(key) ~= "string" or #key < 9 or #key > 13 or not key:match("^%d+$") or not numeric(value) then fail("bucket_invalid") end
        local stamp = tonumber(key)
        if stamp >= 1e11 then stamp = stamp / 1000 end
        if not M.base(stamp) or (mode ~= "overall" and (stamp < expected or stamp >= period_end)) then fail("bucket_outside_period") end
        local aligned
        if mode == "annually" then aligned = Stats.period_start("monthly", stamp)
        elseif mode == "overall" then aligned = Stats.period_start("annually", stamp)
        else aligned = math.floor((stamp + 28800) / 86400) * 86400 - 28800 end
        if aligned ~= stamp then fail("bucket_unaligned") end
        local normalized = string.format("%.0f", stamp)
        if out.readTimes[normalized] ~= nil and out.readTimes[normalized] ~= value then fail("bucket_conflict") end
        out.readTimes[normalized] = value
    end
    for key, bounds in pairs({ readDays = { 1e7 }, dayAverageReadTime = { 1e12 }, compare = { 1e9, -1e9 }, readRate = { 100 } }) do
        if numeric(raw[key], bounds[1], bounds[2]) then out[key] = raw[key] end
    end
    for _, key in ipairs({ "preferCategoryWord", "preferTimeWord" }) do
        if text(raw[key], 8192) then out[key] = raw[key] end
    end
    if type(raw.rank) == "table" and text(raw.rank.text, 8192) then out.rank = { text = raw.rank.text } end
    for _, name in ipairs({ "readLongest", "preferCategory", "preferAuthor", "preferPublisher", "readStat" }) do
        local values = raw[name]
        if values ~= nil then
            if not array(values) then fail("list_invalid") end
            local rows = {}
            for _, row in ipairs(values) do
                if type(row) == "table" then
                    if name == "readLongest" and numeric(row.readTime) then
                        local item, has_title = { readTime = row.readTime }, false
                        for _, fields in ipairs({ { "book", "title", "author" }, { "albumInfo", "name", "authorName" } }) do
                            local source = row[fields[1]]
                            if type(source) == "table" and text(source[fields[2]]) and source[fields[2]] ~= "" then
                                local book = { [fields[2]] = source[fields[2]] }
                                if text(source[fields[3]]) then book[fields[3]] = source[fields[3]] end
                                item[fields[1]], has_title = book, true
                            end
                        end
                        if has_title then rows[#rows + 1] = item end
                    elseif name == "preferCategory" and text(row.categoryTitle) and numeric(row.readingTime) then
                        local item = { categoryTitle = row.categoryTitle, readingTime = row.readingTime }
                        if numeric(row.readingCount, 1e7) then item.readingCount = row.readingCount end
                        rows[#rows + 1] = item
                    elseif name == "readStat" and text(row.stat, 256) and text(row.counts, 256) then
                        rows[#rows + 1] = { stat = row.stat, counts = row.counts }
                    elseif (name == "preferAuthor" or name == "preferPublisher") and text(row.name) and numeric(row.count, 1e7) then
                        rows[#rows + 1] = { name = row.name, count = row.count }
                    end
                end
            end
            out[name] = rows
        end
    end
    return out
end

return M
