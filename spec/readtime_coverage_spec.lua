package.path = "./?.lua;./?/init.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function() return { open = helper.connect } end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return { info = function() end, warn = function() end } end }
end
local Coverage = require("weread.lib.readtime_coverage")
local Crypto = require("weread.lib.crypto")
local ReadReport = require("weread.lib.read_report")
local checks = 0
local function eq(got, expected, label)
    checks = checks + 1
    assert(got == expected, label .. ": " .. tostring(got) .. " ~= " .. tostring(expected))
end
local root = os.tmpname() .. "-coverage"
os.execute("mkdir -p " .. string.format("%q", root))
local now = 100
local journal = Coverage:new(root, function() return now end)
local a, b = string.rep("a", 20), string.rep("b", 20)
eq(journal:initialize(), 100, "tracking boundary persisted")
now = 120
eq(Coverage:new(root, function() return now end):initialize(), 100, "restart does not move boundary")
eq(journal:reserve("../other", 130, 30), nil, "invalid account rejected")
eq(journal:reserve(a, 130, -1), nil, "negative duration rejected")
eq(journal:reserve(a, 10, 30), nil, "invalid interval rejected")
eq(journal:reserve(a, 140, 30), true, "known account coverage committed")
eq(journal:reserve(a, 150, 20), true, "overlapping retry merged")
eq(journal:reserve(a, 160, 10), true, "touching interval merged")
local function preview(key, start, duration)
    return assert(journal:preview(key, { { id = 1, start_time = start, duration = duration } }))
end
local plan = preview(a, 90, 60)
eq(plan.unverified, 10, "pre-journal seconds remain unknown")
eq(plan.eligible, 10, "uncovered tracked prefix eligible")
eq(plan.covered, 40, "merged outgoing ranges counted only once")
eq(plan.parts[1].start_time, 100, "eligible part starts at tracking boundary")
eq(preview(b, 100, 60).eligible, 60, "another account is isolated")
eq(journal:reserve(nil, 175, 10), true, "unidentified outgoing request committed")
eq(preview(a, 150, 30).covered, 20, "known and unidentified coverage unioned")
eq(preview(b, 150, 30).covered, 10, "unidentified request conservatively covers any account")
eq(preview(a, 160, 5).eligible, 5, "half-open touching edge is not double counted")
eq(preview(a, 175, 5).eligible, 5, "end boundary is available")
eq(journal:preview(a, { { id = 1, start_time = 100, duration = 20 },
    { id = 2, start_time = 110, duration = 20 } }), nil, "overlapping offline rows cannot be double counted")
eq(journal:preview(a, { { id = 1, start_time = 100, duration = 10 },
    { id = 1, start_time = 110, duration = 10 } }), nil, "duplicate source rows cannot be planned twice")
eq(journal:preview(a, { { id = 1, start_time = 100, duration = 61 } }), nil, "unbounded segment rejected")
eq(Coverage.subtract(100, 30, 100, { { 120, 110 } }), nil, "corrupt interval rejected")
eq(Coverage.subtract(4102444799, 3, 100, {}), nil, "overflow endpoint rejected")
local first_send = assert(Coverage.subtract(90, 20, 100, { { 95, 105 } }))
eq(first_send.covered, 10, "known first request can cover time before tracking began")
eq(first_send.unverified, 5, "only unrecorded older prefix remains unknown")
eq(first_send.eligible, 5, "uncovered tracked suffix remains available")
-- Independently compare the splitter against an integer-second oracle.
for seed = 1, 40 do
    local ranges, expected = {}, { covered = 0, eligible = 0, unverified = 0 }
    local expected_map = {}
    for i = 1, 6 do
        local first = 90 + (seed * 13 + i * 7) % 50
        ranges[#ranges + 1] = { first, first + (seed + i * 3) % 15 + 1 }
    end
    for at = 95, 144 do
        local name = at < 100 and "unverified" or "eligible"
        for _, range in ipairs(ranges) do if at >= range[1] and at < range[2] then name = "covered" end end
        expected[name] = expected[name] + 1
        expected_map[#expected_map + 1] = name == "eligible" and "1" or "0"
    end
    local split = assert(Coverage.subtract(95, 50, 100, ranges))
    for _, name in ipairs({ "covered", "eligible", "unverified" }) do eq(split[name], expected[name], "oracle " .. name) end
    local seen, actual_map = {}, {}
    for _, part in ipairs(split.parts) do
        for at = part.start_time, part.start_time + part.duration - 1 do
            assert(not seen[at] and at >= 95 and at < 145, "invalid eligible fragment")
            seen[at] = true
        end
    end
    for at = 95, 144 do actual_map[#actual_map + 1] = seen[at] and "1" or "0" end
    eq(table.concat(actual_map), table.concat(expected_map), "exact eligible coordinates match oracle")
end
local db = helper.connect(journal.path)
db:exec([[CREATE TRIGGER fail_coverage BEFORE INSERT ON coverage BEGIN SELECT RAISE(ABORT,'fixture failure'); END]])
db:close()
eq(journal:reserve(a, 180, 40), nil, "merge failure is reported")
eq(preview(a, 150, 30).covered, 20, "failed replacement rolls back old coverage")
db = helper.connect(journal.path)
db:exec("DROP TRIGGER fail_coverage")
db:close()

local cookies = { wr_vid = "123" }
local actual_account = Crypto.sha256_hex("weread-library:123"):sub(1, 20)
local calls, lose_receipt, last_ct = 0, true, nil
local report = ReadReport:new{
    coverage = journal,
    settings = { get = function(_self, key)
        if key == "cookies" then return cookies end
        if key == "read_report" then return { interval_seconds = 30 } end
    end },
    client = { report_read = function(_self, payload)
        if payload.rt and payload.rt > 0 then
            local seen = preview(actual_account, payload.ct - payload.rt, payload.rt)
            eq(seen.covered, payload.rt, "separate DB reader sees committed coverage before HTTP")
            calls = calls + 1
            last_ct = payload.ct
            if lose_receipt then error("synthetic lost acknowledgement") end
        end
        return { succ = 1 }
    end },
    library_db = { accountKey = function() return a end }, -- Different gateway account.
    scheduler = {}, get_document = function() end, detect_book = function() end, subprocess = false,
}
local book = { chapter_uid = 1, pclts = "1" }
local ok = pcall(report._send, report, "book", book, nil, 30)
eq(ok, false, "lost receipt propagates failure")
eq(calls, 1, "one timed request dispatched")
local current = last_ct
eq(preview(a, current - 30, 30).covered, 0, "coverage uses Cookie VID, not stale gateway identity")
eq(preview(actual_account, current - 30, 30).eligible, 0, "lost receipt does not release possibly accepted time")
lose_receipt = false
eq(pcall(report._send, report, "book", book, nil, 0), true, "position-only upload remains available")
eq(calls, 1, "zero-time request creates no positive dispatch")
cookies = {}
eq(pcall(report._send, report, "book", book, nil, 30), true, "unidentified sender is still journaled")
eq(preview(b, last_ct - 30, 30).covered, 30, "unidentified sender cannot escape account coverage")
eq(calls, 2, "unidentified timed send dispatched once")
db = helper.connect(journal.path)
db:exec("DELETE FROM coverage WHERE scope=''") -- Isolate the malformed-VID case.
db:close()
cookies = { wr_vid = "not-a-user-id" }
eq(pcall(report._send, report, "book", book, nil, 30), true, "malformed identity is treated as unidentified")
eq(preview(b, last_ct - 30, 30).covered, 30, "malformed identity cannot hide overlap from other accounts")
db = helper.connect(journal.path)
db:exec([[CREATE TRIGGER fail_send BEFORE INSERT ON coverage BEGIN SELECT RAISE(ABORT,'fixture failure'); END]])
db:close()
eq(pcall(report._send, report, "book", book, nil, 30), false, "storage failure stops positive report")
eq(calls, 3, "no timed HTTP after coverage failure")
eq(pcall(report._send, report, "book", book, nil, 0), true, "position-only sync survives coverage failure")
db = helper.connect(journal.path)
db:exec("DROP TRIGGER fail_send")
db:close()

-- Exhaustion preserves prior evidence, while merging an existing range works.
db = helper.connect(journal.path)
db:exec([[WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<50000)
    INSERT INTO coverage SELECT 'cccccccccccccccccccc',x*3+200, x*3+201 FROM n;]])
db:close()
local saved, err = journal:reserve(b, 190, 5)
eq(saved, nil, "full journal does not evict old ranges")
eq(err, "coverage_full", "full journal distinguished")
eq(journal:reserve(a, 155, 5), true, "existing evidence may merge at capacity")
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(journal.path .. suffix) end
os.remove(root)
print("readtime_coverage_spec: " .. checks .. " checks")
