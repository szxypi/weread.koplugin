package.path = "./?.lua;./?/init.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function() return { open = helper.connect } end
local root = os.tmpname() .. "-offline-time"
os.execute("mkdir -p " .. string.format("%q", root))
package.preload["datastorage"] = function() return { getSettingsDir = function() return root end } end
local Store = require("weread.lib.offline_time_store")
local Stats = require("weread.lib.offline_time_stats")
local Collector = require("weread.lib.offline_time")
local checks = 0
local function eq(got, expected, label)
    checks = checks + 1
    assert(got == expected, label .. ": got " .. tostring(got) .. ", expected " .. tostring(expected))
end
local function expect(value, label) checks = checks + 1 assert(value, label) end
local a, b, c, d, e = string.rep("a", 20), string.rep("b", 20), string.rep("c", 20), string.rep("d", 20), string.rep("e", 20)
local store = Store:new(root)
eq(store:path("../account"), nil, "unsafe account path rejected")
expect(store:recover(a), "fresh ledger opens")
local function window(at, book, stats_book)
    return { start_time = at, book_id = book or "900001", stats_book = stats_book or 1, time_zone = "+08:00", book_version = 2 }
end
local id = assert(store:begin(a, window(100)))
local span = { page = 1, start_time = 95, duration = 10 }
eq(store:collect(a, id, { span }, 105).seconds, 5, "clip prefix from before collection starts")
eq(store:collect(a, id, { span, span }, 105).seconds, 0, "duplicate memory and SQLite tuples ignored")
span.duration = 20
eq(store:collect(a, id, { span }, 115).seconds, 10, "only new suffix recorded")
span.duration = 160
eq(store:collect(a, id, { span }, 255, true).seconds, 140, "long suffix split without loss")
eq(store:summary(a).pending, 155, "total matches clipped native time")
local rows = assert(store:pending(a))
local sum = 0
for _, row in ipairs(rows) do
    expect(row.duration <= 60 and row.start_time >= 100, "bounded segments retain timestamps")
    sum = sum + row.duration
    eq(row.book_version, 2, "capture version retained")
end
eq(sum, 155, "pending transport rows preserve total")
eq(store:collect(a, id, { span }, 300).closed, true, "closed window is immutable")
id = assert(store:begin(a, window(300)))
span = { page = 2, start_time = 300, duration = 5 }
eq(store:collect(a, id, { span }, 305).seconds, 5, "new window captured")
local db = helper.connect(store:path(a))
db:exec([[CREATE TRIGGER fail_mark BEFORE UPDATE ON marks BEGIN SELECT RAISE(ABORT,'fixture failure'); END]])
db:close()
span.duration = 20
local result, err = store:collect(a, id, { span }, 320)
eq(result, nil, "watermark failure fails capture")
eq(err, "storage_error", "storage details not exposed")
eq(store:summary(a).pending, 160, "watermark and new segments roll back together")
db = helper.connect(store:path(a))
db:exec("DROP TRIGGER fail_mark")
db:close()
eq(store:collect(a, id, { span }, 320).seconds, 15, "retry captures exact unsaved suffix once")
rows = assert(store:pending(a))
eq(store:claim(a, { rows[1], rows[1] }, "duplicate"), false, "duplicate IDs cannot dispatch twice")
local changed = { id = rows[1].id, duration = rows[1].duration, start_time = rows[1].start_time,
    book_id = "other", time_zone = rows[1].time_zone, book_version = rows[1].book_version }
eq(store:claim(a, { changed }, "wrong-book"), false, "claim rechecks book metadata")
expect(store:claim(a, rows, "attempt-1"), "pending batch claimed atomically")
eq(store:summary(a).in_flight, 175, "claimed seconds tracked")
eq(store:finish(a, rows, "different-attempt", "confirmed"), 0, "wrong attempt cannot acknowledge")
local reopened = Store:new(root)
expect(reopened:recover(a), "restart recovers ledger")
eq(reopened:summary(a).unknown, 175, "interrupted dispatch becomes uncertain")
eq(#reopened:pending(a), 0, "uncertain dispatch is never replayed")
eq(reopened:finish(a, rows, "attempt-1", "confirmed"), 0, "late result after recovery is ignored")
eq(store:begin(a, window(310)), false, "persisted capture floor rejects backward clock after restart")
eq(store:summary(b).pending, 0, "another account has no captured time")
id = assert(store:begin(b, window(100)))
eq(store:collect(b, id, { { page = 1, start_time = 100, duration = 10 } }, 110, true).seconds, 10, "account has independent floor")
rows = assert(store:pending(b))
expect(store:claim(b, rows, "accepted"), "second account batch claimed")
eq(store:finish(b, rows, "accepted", "confirmed"), 10, "matching receipt confirms once")
eq(store:finish(b, rows, "accepted", "confirmed"), 0, "repeated receipt deduplicated")
eq(store:summary(b).confirmed, 10, "confirmed total survives row cleanup")
eq(store:summary(b).rows, 0, "confirmed rows do not accumulate")

local stats = { id_curr_book = 99, curr_page = 3, settings = { min_sec = 5, max_sec = 120 },
    page_stat = { [3] = { { 2000, 0 } } }, isEnabledAndNotFrozen = function() return true end }
local sources = setmetatable({}, { __mode = "k" })
eq(#Stats.snapshot(stats, 2003, sources), 0, "native minimum respected")
eq(Stats.snapshot(stats, 2007, sources)[1].duration, 7, "current page contributes native elapsed time")
eq(Stats.snapshot(stats, 2500, sources)[1].duration, 120, "idle page respects native maximum")
stats._reading_paused_ts = 2008
eq(Stats.snapshot(stats, 2500, sources)[1].duration, 8, "paused page ends at native pause boundary")
eq(stats.page_stat[3][1][2], 0, "native counters remain unchanged")
stats._reading_paused_ts = nil
db = helper.connect(root .. "/statistics.sqlite3")
db:exec([[CREATE TABLE page_stat_data(id_book INTEGER,page INTEGER,start_time INTEGER,duration INTEGER);
    INSERT INTO page_stat_data VALUES(1,1,1000,30),(2,2,1000,50)]])
db:close()
eq(Stats.persisted(stats, 1000, 1040, 1)[1].duration, 30, "native settled rows read for explicit book")
eq(Stats.persisted(stats, 1000, 1040, 2)[1].duration, 50, "native statistics books remain separate")

local wall, mono, zone, online, account, enabled = 2000, 0, "+08:00", false, c, true
local context = { book_id = "900001", path = "/fixture/chapter.epub", stats = stats }
local scheduled, cancelled = {}, {}
local options = {
    settings = { data_dir = root, get = function(_self, key, default)
        if key == "offline_time" then return { enabled = enabled } end
        return default
    end },
    library_db = { accountKey = function() return account end },
    scheduler = {
        scheduleIn = function(_self, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
        unschedule = function(_self, fn) cancelled[fn] = true end,
    },
    get_context = function() return context end, is_online = function() return online end,
    clock = function() return { wall = wall, monotonic = mono, zone = zone } end,
}
local service = Collector:new(options)
expect(service:start(), "offline collector starts")
expect(service.active and service.task, "active window and timer created")
local initial_tick = service.task
wall, mono = 2007, 7
expect(service:update("timer"), "native statistics captured")
expect(cancelled[initial_tick], "reconcile cancels old timer")
local task_count = #scheduled
initial_tick()
eq(#scheduled, task_count, "stale timer cannot schedule another loop")
eq(service:status().pending, 7, "offline seconds persisted")
service:update("timer")
eq(service:status().pending, 7, "repeated timer does not duplicate seconds")
wall, mono, online = 2009, 9, true
service:update("timer")
eq(service:status().pending, 7, "unobserved reconnect gap not attributed to offline time")
eq(service.active, nil, "online stops offline collection")
wall, mono, online = 2030, 30, false
service:update("network_disconnected", false)
wall, mono = 2036, 36
service:update("timer")
eq(service:status().pending, 13, "online interval excluded after reconnect")
wall, mono, online = 2038, 38, true
service:update("network_connected", true)
eq(service:status().pending, 15, "explicit reconnect event seals trusted offline tail")
wall, mono, online = 2040, 40, false
service:update("network_disconnected", false)
wall, mono = 2046, 46
service:pause()
eq(service:status().pending, 21, "pause seals final trusted seconds")
local before_pause = service:status().pending
wall, mono = 2076, 76
stats.page_stat[3][1][1] = 2030 -- native resume shifts the tuple by its pause duration
service:start()
wall, mono = 2082, 82
service:update("timer")
eq(service:status().pending, before_pause + 6, "shifted native tuple does not replay pre-pause prefix")
wall, mono = 2083, 83
service:suspend()
local before_sleep = service:status().pending
eq(service.task, nil, "suspend cancels timer")
wall, mono = 3000, 83
stats.page_stat[3][1][1] = 2947 -- native resume excludes the suspended wall-clock interval
service:start()
wall, mono = 3006, 89
service:update("timer")
eq(service:status().pending, before_sleep + 6, "sleep duration never becomes offline reading")
local before_clock_change = service:status().pending
wall, mono = 2900, 90
eq(service:update("timer"), false, "backward wall clock seals trusted prefix")
eq(service:status().pending, before_clock_change, "clock jump adds no invented time")
wall, mono = 2906, 96
local restored = Collector:new(options)
eq(restored:start(), false, "restart cannot bypass persisted clock floor")
eq(restored:status().error, "clock_changed", "clock floor has explicit status")
wall, mono = 3010, 200
expect(restored:start(), "clock recovery establishes fresh window")
account = d
wall, mono = 3015, 205
restored:update("account_changed")
eq(restored:status().pending, 0, "account change cannot transfer previous account's prefix")
eq(store:summary(c).pending, before_clock_change, "previous account's seconds remain intact")
enabled = false
restored:stop("disabled")
restored:start()
eq(restored.active, nil, "disabled recorder cannot create a window")
eq(restored.task, nil, "disabled recorder has no poll task")
enabled, account, wall, mono = true, d, 3020, 210
stats._reading_paused_ts = 3015
restored:resume()
local resume = restored.task
eq(restored.active, nil, "resume waits for native statistics listener")
stats._reading_paused_ts = nil
stats.page_stat[3][1][1] = 3015
resume()
expect(restored.active, "resume works when native statistics handles the event later")
local stable = restored:status().pending
db = helper.connect(store:path(d))
db:exec([[CREATE TRIGGER reject_segment BEFORE INSERT ON segments BEGIN SELECT RAISE(ABORT,'fixture failure'); END]])
db:close()
wall, mono = 3030, 220
eq(restored:update("timer"), false, "capture write failure is reported")
eq(restored.active.last_seen, 3020, "failed save does not advance scan watermark")
eq(restored:status().pending, stable, "failed capture leaves earlier records intact")
db = helper.connect(store:path(d))
db:exec("DROP TRIGGER reject_segment")
db:close()
expect(restored:update("timer"), "storage recovery retries native suffix")
eq(restored:status().pending, stable + 10, "storage retry captures suffix once")
context.visible, wall, mono = false, 3040, 230
restored:update("timer")
eq(restored.active, nil, "covered reader is not recorded as reading")
eq(restored:status().pending, stable + 10, "unobserved overlay interval is excluded")
eq(restored:status().state, "reader_hidden", "covered reader has explicit status")
context.visible = true
restored:suspend()
enabled = false

id = assert(store:begin(e, window(4000)))
db = helper.connect(store:path(e))
db:exec("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<50000) INSERT INTO segments(window_id,start_time,duration) SELECT " .. id .. ",4000,1 FROM n")
db:close()
result, err = store:collect(e, id, { { page = 1, start_time = 4000, duration = 5 } }, 4005)
eq(result, nil, "full ledger never overwrites earlier time")
eq(err, "ledger_full", "full ledger is distinguishable from storage failure")
eq(store:summary(e).pending, 50000, "ledger-full failure rolls back the new suffix")
for _, key in ipairs({ a, b, c, d, e }) do
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(store:path(key) .. suffix) end
end
os.remove(root .. "/statistics.sqlite3")
os.remove(root)
print("offline_time_spec: " .. checks .. " checks")
